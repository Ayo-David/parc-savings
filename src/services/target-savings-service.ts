import { createHash, randomUUID } from "node:crypto";
import { Decimal } from "decimal.js";
import type { Knex } from "knex";
import { withTenantTransaction } from "../database/client.js";
import type { SavingsLedgerGateway } from "./ledger-gateway.js";

type WithdrawalKind = "PARTIAL" | "BREAK";

export class TargetSavingsService {
  public constructor(
    private readonly database: Knex,
    private readonly ledger: SavingsLedgerGateway,
  ) {}

  public async createGoal(input: {
    tenantId: string;
    customerId: string;
    accountId: string;
    name: string;
    targetAmountMinor: string;
    currency: "NGN";
    targetDate: string;
    correlationId: string;
    idempotencyKey: string;
  }): Promise<{
    id: string;
    savingsAccountId: string;
    targetAmountMinor: string;
    currency: "NGN";
    targetDate: string;
    status: "ACTIVE";
    replayed: boolean;
  }> {
    const requestHash = hash({
      customerId: input.customerId,
      accountId: input.accountId,
      name: input.name,
      targetAmountMinor: input.targetAmountMinor,
      currency: input.currency,
      targetDate: input.targetDate,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      const existing = await trx("savings_goals")
        .where({
          tenant_id: input.tenantId,
          creation_idempotency_key: input.idempotencyKey,
        })
        .first<{
          id: string;
          savings_account_id: string;
          target_amount: string;
          currency: string;
          target_date: string;
          status: string;
          creation_request_hash: string;
        }>(
          "id",
          "savings_account_id",
          "target_amount",
          "currency",
          trx.raw("to_char(target_date,'YYYY-MM-DD') AS target_date"),
          "status",
          "creation_request_hash",
        );
      if (existing) {
        if (existing.creation_request_hash !== requestHash)
          throw new Error("Goal-creation idempotency conflict");
        return {
          id: existing.id,
          savingsAccountId: existing.savings_account_id,
          targetAmountMinor: existing.target_amount,
          currency: "NGN",
          targetDate: existing.target_date,
          status: "ACTIVE",
          replayed: true,
        };
      }
      const account = await trx("savings_accounts as a")
        .join("savings_product_versions as v", function joinVersion() {
          this.on("v.tenant_id", "=", "a.tenant_id").andOn(
            "v.id",
            "=",
            "a.product_version_id",
          );
        })
        .where({
          "a.tenant_id": input.tenantId,
          "a.id": input.accountId,
          "a.customer_id": input.customerId,
          "a.currency": input.currency,
          "a.status": "ACTIVE",
          "v.product_type": "TARGET",
        })
        .forUpdate()
        .first<{ terms_hash: string; terms: Record<string, unknown> }>(
          "v.terms_hash",
          "v.terms",
        );
      if (!account) throw new Error("Active target savings account not found");
      const targetDate = new Date(`${input.targetDate}T00:00:00.000Z`);
      if (Number.isNaN(targetDate.valueOf()) || targetDate <= new Date())
        throw new Error("Target date must be in the future");
      const terms = account.terms;
      if (
        terms.partialWithdrawalLimitPercent !== "50" ||
        terms.partialWithdrawalCount !== 1 ||
        terms.withdrawnInterestForfeiture !== true ||
        terms.breakForfeitsAllInterest !== true
      )
        throw new Error(
          "Target product does not contain the approved withdrawal policy",
        );
      const id = randomUUID();
      await trx("savings_goals").insert({
        id,
        tenant_id: input.tenantId,
        savings_account_id: input.accountId,
        customer_id: input.customerId,
        goal_reference: `SVG-${id}`,
        goal_name: input.name,
        target_amount: input.targetAmountMinor,
        current_amount: "0",
        currency: input.currency,
        target_date: input.targetDate,
        status: "ACTIVE",
        creation_idempotency_key: input.idempotencyKey,
        creation_request_hash: requestHash,
        product_terms_hash: account.terms_hash,
        partial_withdrawal_limit_rate: "50.0000000000",
        partial_withdrawal_limit_count: 1,
        withdrawn_interest_forfeiture: true,
        break_forfeits_all_interest: true,
      });
      await this.outbox(trx, input, id, "savings.goal-created.v1", {
        goal_id: id,
        savings_account_id: input.accountId,
        customer_id: input.customerId,
        target_amount_minor: input.targetAmountMinor,
        currency: input.currency,
        target_date: input.targetDate,
      });
      return {
        id,
        savingsAccountId: input.accountId,
        targetAmountMinor: input.targetAmountMinor,
        currency: input.currency,
        targetDate: input.targetDate,
        status: "ACTIVE",
        replayed: false,
      };
    });
  }

  public partialWithdraw(input: {
    tenantId: string;
    customerId: string;
    goalId: string;
    amountMinor: string;
    currency: "NGN";
    correlationId: string;
    idempotencyKey: string;
  }) {
    return this.withdraw("PARTIAL", input);
  }

  public breakGoal(input: {
    tenantId: string;
    customerId: string;
    goalId: string;
    currency: "NGN";
    correlationId: string;
    idempotencyKey: string;
  }) {
    return this.withdraw("BREAK", input);
  }

  private async withdraw(
    kind: WithdrawalKind,
    input: {
      tenantId: string;
      customerId: string;
      goalId: string;
      amountMinor?: string;
      currency: "NGN";
      correlationId: string;
      idempotencyKey: string;
    },
  ): Promise<{
    withdrawalId: string;
    goalId: string;
    principalMinor: string;
    forfeitedInterestMinor: string;
    ledgerTransactionId: string;
    currency: "NGN";
    goalStatus: "ACTIVE" | "CANCELLED";
    status: "SUCCESSFUL";
    replayed: boolean;
  }> {
    const requestHash = hash({
      kind,
      customerId: input.customerId,
      goalId: input.goalId,
      amountMinor: input.amountMinor ?? null,
      currency: input.currency,
    });
    const prepared = await withTenantTransaction(
      this.database,
      input.tenantId,
      async (trx) => {
        const existing = await trx("savings_goal_withdrawals")
          .where({
            tenant_id: input.tenantId,
            idempotency_key: input.idempotencyKey,
          })
          .first<{
            id: string;
            withdrawal_id: string;
            goal_id: string;
            amount: string;
            forfeited_interest_minor: string;
            status: string;
            request_hash: string;
            ledger_transaction_id: string | null;
          }>();
        if (existing) {
          if (existing.request_hash !== requestHash)
            throw new Error("Goal-withdrawal idempotency conflict");
          return { operation: existing, context: null };
        }
        const goal = await trx("savings_goals as g")
          .join("savings_accounts as a", function joinAccount() {
            this.on("a.tenant_id", "=", "g.tenant_id").andOn(
              "a.id",
              "=",
              "g.savings_account_id",
            );
          })
          .where({
            "g.tenant_id": input.tenantId,
            "g.id": input.goalId,
            "g.customer_id": input.customerId,
            "g.currency": input.currency,
            "g.status": "ACTIVE",
            "a.status": "ACTIVE",
          })
          .forUpdate()
          .first<{
            savings_account_id: string;
            current_amount: string;
            accrued_interest: string;
            matured: boolean;
            partial_withdrawal_count: number;
            ledger_account_id: string;
          }>(
            "g.savings_account_id",
            "g.current_amount",
            "g.accrued_interest",
            trx.raw(
              "g.target_date <= (now() AT TIME ZONE 'UTC')::date AS matured",
            ),
            "g.partial_withdrawal_count",
            "a.ledger_account_id",
          );
        if (!goal) throw new Error("Active target savings goal not found");
        if (goal.matured)
          throw new Error("Matured target savings cannot use early withdrawal");
        // The goal row is locked, so this check is atomic across kinds.
        const pending = await trx("savings_goal_withdrawals")
          .where({
            tenant_id: input.tenantId,
            goal_id: input.goalId,
            status: "PENDING",
          })
          .first<{ id: string } | undefined>("id");
        if (pending) throw new Error("A goal withdrawal is already pending");
        const current = BigInt(goal.current_amount);
        const amount =
          kind === "BREAK" ? current : BigInt(input.amountMinor ?? "0");
        if (amount <= 0n || amount > current)
          throw new Error("Withdrawal exceeds target principal");
        if (
          kind === "PARTIAL" &&
          (goal.partial_withdrawal_count >= 1 || amount * 100n > current * 50n)
        )
          throw new Error(
            "Partial withdrawal exceeds the one-time 50 percent policy",
          );
        const forfeitedInterestMinor = new Decimal(goal.accrued_interest)
          .mul(new Decimal(amount.toString()).div(current.toString()))
          .mul(100)
          .toDecimalPlaces(0, Decimal.ROUND_HALF_EVEN)
          .toFixed(0);
        const withdrawalId = randomUUID();
        const goalWithdrawalId = randomUUID();
        await trx("savings_withdrawals").insert({
          id: withdrawalId,
          tenant_id: input.tenantId,
          savings_account_id: goal.savings_account_id,
          customer_id: input.customerId,
          withdrawal_reference: `SVW-${withdrawalId}`,
          amount: amount.toString(),
          fee_amount: "0",
          currency: input.currency,
          channel: "INTERNAL_TRANSFER",
          status: "PENDING",
          operation_id: randomUUID(),
          idempotency_key: `goal:${input.idempotencyKey}`,
          correlation_id: input.correlationId,
          request_hash: requestHash,
        });
        await trx("savings_goal_withdrawals").insert({
          id: goalWithdrawalId,
          tenant_id: input.tenantId,
          goal_id: input.goalId,
          customer_id: input.customerId,
          amount: amount.toString(),
          currency: input.currency,
          status: "PENDING",
          withdrawal_id: withdrawalId,
          withdrawal_reference: `SVW-${withdrawalId}`,
          withdrawal_kind: kind,
          forfeited_interest_minor: forfeitedInterestMinor,
          idempotency_key: input.idempotencyKey,
          request_hash: requestHash,
        });
        return {
          operation: {
            id: goalWithdrawalId,
            withdrawal_id: withdrawalId,
            goal_id: input.goalId,
            amount: amount.toString(),
            forfeited_interest_minor: forfeitedInterestMinor,
            status: "PENDING",
            request_hash: requestHash,
            ledger_transaction_id: null,
          },
          context: { ...goal },
        };
      },
    );
    if (
      prepared.operation.status === "SUCCESSFUL" &&
      prepared.operation.ledger_transaction_id
    )
      return this.result(
        kind,
        prepared.operation,
        prepared.operation.ledger_transaction_id,
        true,
      );
    const context =
      prepared.context ??
      (await withTenantTransaction(this.database, input.tenantId, (trx) =>
        trx("savings_goals as g")
          .join("savings_accounts as a", function joinAccount() {
            this.on("a.tenant_id", "=", "g.tenant_id").andOn(
              "a.id",
              "=",
              "g.savings_account_id",
            );
          })
          .where({ "g.tenant_id": input.tenantId, "g.id": input.goalId })
          .first<{ savings_account_id: string; ledger_account_id: string }>(
            "g.savings_account_id",
            "a.ledger_account_id",
          ),
      ));
    if (!context) throw new Error("Target savings context not found");
    const wallet = await this.ledger.provisionAccount({
      tenantId: input.tenantId,
      customerId: input.customerId,
      purpose: "WALLET",
      currency: input.currency,
      idempotencyKey: `goal-withdrawal:${input.idempotencyKey}:wallet`,
    });
    const ledgerRequestHash = hash({
      savingsAccountId: context.ledger_account_id,
      walletAccountId: wallet.accountId,
      amountMinor: prepared.operation.amount,
      currency: input.currency,
    });
    const posting = await this.ledger.postWithdrawal({
      tenantId: input.tenantId,
      savingsAccountId: context.ledger_account_id,
      walletAccountId: wallet.accountId,
      amountMinor: prepared.operation.amount,
      currency: input.currency,
      reference: `SVW-${prepared.operation.withdrawal_id}`,
      idempotencyKey: `goal-withdrawal:${input.idempotencyKey}:posting`,
    });
    const balance = await this.ledger.getBalance({
      tenantId: input.tenantId,
      accountId: context.ledger_account_id,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      const changed = await trx("savings_withdrawals")
        .where({
          tenant_id: input.tenantId,
          id: prepared.operation.withdrawal_id,
          status: "PENDING",
        })
        .update({
          status: "SUCCESSFUL",
          ledger_transaction_id: posting.transactionId,
          ledger_journal_id: posting.journalId,
          ledger_request_hash: ledgerRequestHash,
          ledger_posted_at: trx.fn.now(),
          processed_at: trx.fn.now(),
        });
      if (changed === 1) {
        await trx("savings_goal_withdrawals")
          .where({
            tenant_id: input.tenantId,
            id: prepared.operation.id,
            status: "PENDING",
          })
          .update({
            status: "SUCCESSFUL",
            ledger_transaction_id: posting.transactionId,
            ledger_journal_id: posting.journalId,
            ledger_request_hash: ledgerRequestHash,
            ledger_posted_at: trx.fn.now(),
            processed_at: trx.fn.now(),
          });
        await trx("savings_accounts")
          .where({ tenant_id: input.tenantId, id: context.savings_account_id })
          .update({
            total_withdrawn: trx.raw("total_withdrawn + ?::bigint", [
              prepared.operation.amount,
            ]),
          });
        // A concurrent operation may already have stored a newer ledger snapshot.
        await trx("savings_accounts")
          .where({ tenant_id: input.tenantId, id: context.savings_account_id })
          .where("last_ledger_sequence", "<", balance.version)
          .update({
            current_balance: balance.postedBalanceMinor,
            held_balance: balance.heldBalanceMinor,
            last_ledger_sequence: balance.version,
            ledger_synced_at: trx.fn.now(),
          });
        await trx("savings_goals")
          .where({
            tenant_id: input.tenantId,
            id: input.goalId,
            status: "ACTIVE",
          })
          .update(
            kind === "PARTIAL"
              ? {
                  current_amount: trx.raw("current_amount - ?::bigint", [
                    prepared.operation.amount,
                  ]),
                  partial_withdrawal_count: trx.raw(
                    "partial_withdrawal_count + 1",
                  ),
                  accrued_interest: trx.raw(
                    "greatest(accrued_interest - (?::numeric/100),0)",
                    [prepared.operation.forfeited_interest_minor],
                  ),
                }
              : {
                  current_amount: 0,
                  accrued_interest: 0,
                  status: "CANCELLED",
                  broken_at: trx.fn.now(),
                  lifecycle_evidence: {
                    withdrawal_id: prepared.operation.id,
                    ledger_transaction_id: posting.transactionId,
                    forfeited_interest_minor:
                      prepared.operation.forfeited_interest_minor,
                  },
                },
          );
        const eventType =
          kind === "PARTIAL"
            ? "savings.goal-partially-withdrawn.v1"
            : "savings.goal-broken.v1";
        await this.outbox(trx, input, input.goalId, eventType, {
          goal_id: input.goalId,
          goal_withdrawal_id: prepared.operation.id,
          savings_account_id: context.savings_account_id,
          ledger_transaction_id: posting.transactionId,
          principal_minor: prepared.operation.amount,
          forfeited_interest_minor: prepared.operation.forfeited_interest_minor,
          currency: input.currency,
        });
      }
      return this.result(
        kind,
        prepared.operation,
        posting.transactionId,
        changed !== 1 || posting.replayed,
      );
    });
  }

  private result(
    kind: WithdrawalKind,
    operation: {
      id: string;
      goal_id: string;
      amount: string;
      forfeited_interest_minor: string;
    },
    ledgerTransactionId: string,
    replayed: boolean,
  ) {
    return {
      withdrawalId: operation.id,
      goalId: operation.goal_id,
      principalMinor: operation.amount,
      forfeitedInterestMinor: operation.forfeited_interest_minor,
      ledgerTransactionId,
      currency: "NGN" as const,
      goalStatus:
        kind === "BREAK" ? ("CANCELLED" as const) : ("ACTIVE" as const),
      status: "SUCCESSFUL" as const,
      replayed,
    };
  }

  private async outbox(
    trx: Knex.Transaction,
    input: { tenantId: string; correlationId: string; idempotencyKey: string },
    aggregateId: string,
    eventType: string,
    payload: object,
  ): Promise<void> {
    await trx("savings_outbox_events").insert({
      tenant_id: input.tenantId,
      aggregate_type: "savings_goal",
      aggregate_id: aggregateId,
      aggregate_version: 1,
      event_type: eventType,
      event_version: 1,
      correlation_id: input.correlationId,
      request_id: input.idempotencyKey,
      partition_key: `${input.tenantId}:${aggregateId}`,
      payload,
    });
  }
}

function hash(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}
