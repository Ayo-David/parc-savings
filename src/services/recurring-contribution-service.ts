import { createHash, randomUUID } from "node:crypto";
import type { Knex } from "knex";
import { withTenantTransaction } from "../database/client.js";
import type { SavingsLedgerGateway } from "./ledger-gateway.js";
import type { OrdinarySavingsService } from "./ordinary-savings-service.js";

type Frequency = "DAILY" | "WEEKLY" | "MONTHLY";

export class RecurringContributionService {
  public constructor(
    private readonly database: Knex,
    private readonly ledger: SavingsLedgerGateway,
    private readonly contributions: OrdinarySavingsService,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  public async create(input: {
    tenantId: string;
    customerId: string;
    savingsAccountId: string;
    goalId?: string;
    amountMinor: string;
    currency: "NGN";
    frequency: Frequency;
    startDate: string;
    endDate?: string;
    maxExecutions?: number;
    executionTime: string;
    timezone: string;
    consentReference: string;
    correlationId: string;
    idempotencyKey: string;
  }) {
    const requestHash = hash({
      customerId: input.customerId,
      savingsAccountId: input.savingsAccountId,
      goalId: input.goalId ?? null,
      amountMinor: input.amountMinor,
      currency: input.currency,
      frequency: input.frequency,
      startDate: input.startDate,
      endDate: input.endDate ?? null,
      maxExecutions: input.maxExecutions ?? null,
      executionTime: input.executionTime,
      timezone: input.timezone,
    });
    const prior = await withTenantTransaction(
      this.database,
      input.tenantId,
      (trx) =>
        trx("savings_recurring_plans")
          .where({
            tenant_id: input.tenantId,
            creation_idempotency_key: input.idempotencyKey,
          })
          .first<Record<string, unknown>>(),
    );
    if (prior) return this.planResult(prior, requestHash, true);
    const wallet = await this.ledger.provisionAccount({
      tenantId: input.tenantId,
      customerId: input.customerId,
      purpose: "WALLET",
      currency: input.currency,
      idempotencyKey: `recurring:${input.idempotencyKey}:wallet`,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      const replay = await trx("savings_recurring_plans")
        .where({
          tenant_id: input.tenantId,
          creation_idempotency_key: input.idempotencyKey,
        })
        .first<Record<string, unknown>>();
      if (replay) return this.planResult(replay, requestHash, true);
      const id = randomUUID();
      const row = {
        id,
        tenant_id: input.tenantId,
        savings_account_id: input.savingsAccountId,
        customer_id: input.customerId,
        goal_id: input.goalId ?? null,
        plan_reference: `SRP-${id}`,
        amount: input.amountMinor,
        currency: input.currency,
        frequency: input.frequency,
        start_date: input.startDate,
        end_date: input.endDate ?? null,
        next_execution_date: input.startDate,
        max_executions: input.maxExecutions ?? null,
        source_account_id: wallet.accountId,
        status: "ACTIVE",
        funding_source: "WALLET",
        timezone_name: input.timezone,
        execution_time: input.executionTime,
        retry_limit: 3,
        creation_idempotency_key: input.idempotencyKey,
        creation_request_hash: requestHash,
        correlation_id: input.correlationId,
        consent_reference: input.consentReference,
        schedule_snapshot: {
          frequency: input.frequency,
          timezone: input.timezone,
          execution_time: input.executionTime,
          month_end_policy: "LAST_VALID_DAY",
          funding_source: "WALLET",
        },
      };
      await trx("savings_recurring_plans").insert(row);
      await this.event(trx, input, id, "savings.recurring-plan-created.v1", {
        recurring_plan_id: id,
        savings_account_id: input.savingsAccountId,
        customer_id: input.customerId,
        amount_minor: input.amountMinor,
        currency: input.currency,
        frequency: input.frequency,
        next_execution_date: input.startDate,
      });
      return this.planResult(row, requestHash, false);
    });
  }

  public async execute(input: {
    tenantId: string;
    planId: string;
    scheduledDate: string;
    correlationId: string;
    idempotencyKey: string;
    workerId: string;
  }) {
    const requestHash = hash({
      planId: input.planId,
      scheduledDate: input.scheduledDate,
    });
    const prepared = await withTenantTransaction(
      this.database,
      input.tenantId,
      async (trx) => {
        // Lock the plan first so concurrent workers serialize on it.
        const plan = await trx("savings_recurring_plans")
          .where({ tenant_id: input.tenantId, id: input.planId })
          .forUpdate()
          .first<Record<string, unknown>>();
        const existing = await trx("savings_recurring_executions")
          .where({
            tenant_id: input.tenantId,
            recurring_plan_id: input.planId,
            scheduled_date: input.scheduledDate,
          })
          .forUpdate()
          .first<Record<string, unknown>>();
        // A completed occurrence replays even if it exhausted the plan.
        if (existing?.status === "SUCCESSFUL")
          return { execution: existing, plan: null };
        if (!plan || plan.status !== "ACTIVE" || plan.is_active !== true)
          throw new Error("Active recurring plan not found");
        if (dateOnly(plan.next_execution_date) !== input.scheduledDate)
          throw new Error(
            "Scheduled date does not match the plan's next execution",
          );
        if (input.scheduledDate > this.clock().toISOString().slice(0, 10))
          throw new Error("Recurring execution is not due");
        if (existing) {
          if (existing.request_hash !== requestHash)
            throw new Error("Recurring execution conflict");
          if (
            existing.lease_expires_at &&
            new Date(scalarString(existing.lease_expires_at)) > this.clock()
          )
            throw new Error("Recurring execution is already claimed");
          if (
            existing.next_retry_at &&
            new Date(scalarString(existing.next_retry_at)) > this.clock()
          )
            throw new Error("Recurring execution retry is not due");
          await trx("savings_recurring_executions")
            .where({ tenant_id: input.tenantId, id: existing.id })
            .update({
              status: "PROCESSING",
              locked_at: this.clock(),
              locked_by: input.workerId,
              lease_expires_at: new Date(this.clock().getTime() + 60_000),
              attempted_at: this.clock(),
              attempt_count: trx.raw("attempt_count + 1"),
            });
          return {
            execution: {
              ...existing,
              status: "PROCESSING",
              attempt_count: Number(existing.attempt_count) + 1,
            },
            plan,
          };
        }
        const id = randomUUID();
        const execution: Record<string, unknown> = {
          id,
          tenant_id: input.tenantId,
          recurring_plan_id: input.planId,
          execution_number: Number(plan.execution_count) + 1,
          scheduled_date: input.scheduledDate,
          amount: plan.amount,
          status: "PROCESSING",
          attempted_at: this.clock(),
          attempt_count: 1,
          locked_at: this.clock(),
          locked_by: input.workerId,
          lease_expires_at: new Date(this.clock().getTime() + 60_000),
          operation_id: randomUUID(),
          idempotency_key: input.idempotencyKey,
          correlation_id: input.correlationId,
          request_id: input.idempotencyKey,
          request_hash: requestHash,
        };
        await trx("savings_recurring_executions").insert(execution);
        return { execution, plan };
      },
    );
    if (!prepared.plan) return this.executionResult(prepared.execution, true);
    const plan = prepared.plan;
    try {
      const contribution = await this.contributions.contribute({
        tenantId: input.tenantId,
        customerId: String(plan.customer_id),
        accountId: String(plan.savings_account_id),
        ...(plan.goal_id ? { goalId: scalarString(plan.goal_id) } : {}),
        amountMinor: String(plan.amount),
        currency: "NGN",
        correlationId: input.correlationId,
        idempotencyKey: `recurring:${input.planId}:${input.scheduledDate}`,
      });
      return withTenantTransaction(
        this.database,
        input.tenantId,
        async (trx) => {
          const deposit = await trx("savings_deposits")
            .where({
              tenant_id: input.tenantId,
              id: contribution.contributionId,
            })
            .first<Record<string, unknown>>();
          if (!deposit)
            throw new Error("Recurring contribution evidence not found");
          const changed = await trx("savings_recurring_executions")
            .where({
              tenant_id: input.tenantId,
              id: prepared.execution.id,
              status: "PROCESSING",
            })
            .update({
              status: "SUCCESSFUL",
              deposit_id: contribution.contributionId,
              ledger_transaction_id: deposit.ledger_transaction_id,
              ledger_journal_id: deposit.ledger_journal_id,
              ledger_request_hash: deposit.ledger_request_hash,
              ledger_posted_at: deposit.ledger_posted_at,
              completed_at: this.clock(),
              terminal_at: this.clock(),
              locked_at: null,
              locked_by: null,
              lease_expires_at: null,
            });
          if (changed !== 1) {
            const current = await trx("savings_recurring_executions")
              .where({ tenant_id: input.tenantId, id: prepared.execution.id })
              .first<Record<string, unknown>>();
            if (current?.status === "SUCCESSFUL")
              return this.executionResult(current, true);
            throw new Error("Recurring execution is no longer claimed");
          }
          const next = nextDate(
            input.scheduledDate,
            String(plan.frequency) as Frequency,
          );
          const count = Number(plan.execution_count) + 1;
          const exhausted =
            (plan.max_executions !== null &&
              count >= Number(plan.max_executions)) ||
            (plan.end_date !== null && next > dateOnly(plan.end_date));
          const [updated] = await trx("savings_recurring_plans")
            .where({ tenant_id: input.tenantId, id: input.planId })
            .update({
              execution_count: count,
              next_execution_date: exhausted ? null : next,
              status: exhausted ? "EXHAUSTED" : "ACTIVE",
              is_active: !exhausted,
              completed_at: exhausted ? this.clock() : null,
            })
            .returning<Array<{ aggregate_version: string }>>(
              "aggregate_version",
            );
          if (!updated) throw new Error("Recurring plan not found");
          await this.event(
            trx,
            input,
            input.planId,
            "savings.recurring-contribution-succeeded.v1",
            {
              recurring_plan_id: input.planId,
              recurring_execution_id: String(prepared.execution.id),
              contribution_id: contribution.contributionId,
              savings_account_id: String(plan.savings_account_id),
              ledger_transaction_id: contribution.ledgerTransactionId,
              amount_minor: String(plan.amount),
              currency: "NGN",
              scheduled_date: input.scheduledDate,
            },
            Number(updated.aggregate_version),
          );
          const saved = await trx("savings_recurring_executions")
            .where({ tenant_id: input.tenantId, id: prepared.execution.id })
            .first<Record<string, unknown>>();
          if (!saved)
            throw new Error("Successful recurring execution was not persisted");
          return this.executionResult(saved, false);
        },
      );
    } catch (error) {
      return withTenantTransaction(
        this.database,
        input.tenantId,
        async (trx) => {
          const attempts = Number(prepared.execution.attempt_count);
          const exhausted = attempts >= Number(plan.retry_limit);
          const message =
            error instanceof Error
              ? error.message
              : "Recurring contribution failed";
          const changed = await trx("savings_recurring_executions")
            .where({
              tenant_id: input.tenantId,
              id: prepared.execution.id,
              status: "PROCESSING",
              locked_by: input.workerId,
            })
            .update({
              status: "FAILED",
              failure_reason: message,
              failure_code: "LEDGER_CONTRIBUTION_FAILED",
              retry_classification: exhausted ? "TERMINAL" : "RETRYABLE",
              next_retry_at: exhausted
                ? null
                : new Date(this.clock().getTime() + 5 * 60_000),
              terminal_at: exhausted ? this.clock() : null,
              locked_at: null,
              locked_by: null,
              lease_expires_at: null,
            });
          if (changed !== 1) {
            // Another worker owns this occurrence now; leave it to them.
            const current = await trx("savings_recurring_executions")
              .where({ tenant_id: input.tenantId, id: prepared.execution.id })
              .first<Record<string, unknown>>();
            if (!current) throw new Error("Recurring execution not found");
            return this.executionResult(current, false);
          }
          if (exhausted) {
            const next = nextDate(
              input.scheduledDate,
              String(plan.frequency) as Frequency,
            );
            const count = Number(plan.execution_count) + 1;
            const planExhausted =
              (plan.max_executions !== null &&
                count >= Number(plan.max_executions)) ||
              (plan.end_date !== null && next > dateOnly(plan.end_date));
            await trx("savings_recurring_plans")
              .where({ tenant_id: input.tenantId, id: input.planId })
              .update({
                execution_count: count,
                next_execution_date: planExhausted ? null : next,
                status: planExhausted ? "EXHAUSTED" : "ACTIVE",
                is_active: !planExhausted,
                completed_at: planExhausted ? this.clock() : null,
              });
          }
          await this.event(
            trx,
            input,
            String(prepared.execution.id),
            "savings.recurring-contribution-failed.v1",
            {
              recurring_plan_id: input.planId,
              recurring_execution_id: String(prepared.execution.id),
              savings_account_id: String(plan.savings_account_id),
              amount_minor: String(plan.amount),
              currency: "NGN",
              scheduled_date: input.scheduledDate,
              retryable: !exhausted,
              failure_code: "LEDGER_CONTRIBUTION_FAILED",
            },
            // Each attempt is a distinct fact of this execution.
            attempts,
            "recurring_execution",
          );
          const saved = await trx("savings_recurring_executions")
            .where({ tenant_id: input.tenantId, id: prepared.execution.id })
            .first<Record<string, unknown>>();
          if (!saved)
            throw new Error("Failed recurring execution was not persisted");
          return this.executionResult(saved, false);
        },
      );
    }
  }

  private planResult(
    row: Record<string, unknown>,
    requestHash: string,
    replayed: boolean,
  ) {
    if (row.creation_request_hash !== requestHash)
      throw new Error("Recurring-plan idempotency conflict");
    return {
      recurringPlanId: String(row.id),
      savingsAccountId: String(row.savings_account_id),
      amountMinor: String(row.amount),
      currency: "NGN" as const,
      frequency: String(row.frequency),
      nextExecutionDate: dateOnly(row.next_execution_date),
      status: String(row.status),
      replayed,
    };
  }

  private executionResult(row: Record<string, unknown>, replayed: boolean) {
    return {
      recurringExecutionId: String(row.id),
      recurringPlanId: String(row.recurring_plan_id),
      scheduledDate: dateOnly(row.scheduled_date),
      amountMinor: String(row.amount),
      currency: "NGN" as const,
      status: String(row.status),
      ledgerTransactionId: row.ledger_transaction_id
        ? scalarString(row.ledger_transaction_id)
        : undefined,
      replayed,
    };
  }

  private async event(
    trx: Knex.Transaction,
    input: { tenantId: string; correlationId: string; idempotencyKey: string },
    aggregateId: string,
    eventType: string,
    payload: object,
    version = 1,
    aggregateType: "recurring_plan" | "recurring_execution" = "recurring_plan",
  ) {
    await trx("savings_outbox_events").insert({
      tenant_id: input.tenantId,
      aggregate_type: aggregateType,
      aggregate_id: aggregateId,
      aggregate_version: version,
      event_type: eventType,
      event_version: 1,
      correlation_id: input.correlationId,
      request_id: input.idempotencyKey,
      partition_key: `${input.tenantId}:${aggregateType}:${aggregateId}`,
      payload,
    });
  }
}

function nextDate(value: string, frequency: Frequency): string {
  const date = new Date(`${value}T00:00:00.000Z`);
  if (frequency === "DAILY") date.setUTCDate(date.getUTCDate() + 1);
  else if (frequency === "WEEKLY") date.setUTCDate(date.getUTCDate() + 7);
  else {
    const day = date.getUTCDate();
    date.setUTCDate(1);
    date.setUTCMonth(date.getUTCMonth() + 1);
    const last = new Date(
      Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 0),
    ).getUTCDate();
    date.setUTCDate(Math.min(day, last));
  }
  return date.toISOString().slice(0, 10);
}
function dateOnly(value: unknown): string {
  if (!(value instanceof Date)) return String(value).slice(0, 10);
  return `${value.getFullYear().toString().padStart(4, "0")}-${(
    value.getMonth() + 1
  )
    .toString()
    .padStart(2, "0")}-${value.getDate().toString().padStart(2, "0")}`;
}
function hash(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}
function scalarString(value: unknown): string {
  if (
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "bigint" ||
    value instanceof Date
  )
    return String(value);
  throw new Error("Expected scalar database value");
}
