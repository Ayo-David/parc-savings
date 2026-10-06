import { createHash, randomUUID } from "node:crypto";
import { Decimal } from "decimal.js";
import type { Knex } from "knex";
import { withTenantTransaction } from "../database/client.js";
import type { SavingsLedgerGateway } from "./ledger-gateway.js";

export class InterestService {
  public constructor(
    private readonly database: Knex,
    private readonly ledger: SavingsLedgerGateway,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  public async accrue(input: {
    tenantId: string;
    accountId: string;
    accrualDate: string;
    currency: "NGN";
    correlationId: string;
    idempotencyKey: string;
  }) {
    const requestHash = hash({
      accountId: input.accountId,
      accrualDate: input.accrualDate,
      currency: input.currency,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      const existing = await trx("savings_interest_accruals")
        .where({
          tenant_id: input.tenantId,
          savings_account_id: input.accountId,
          accrual_date: input.accrualDate,
        })
        .first<Record<string, unknown>>();
      if (existing) return this.accrualResult(existing, requestHash, true);
      let batch = await trx("savings_interest_accrual_batches")
        .where({
          tenant_id: input.tenantId,
          accrual_date: input.accrualDate,
          currency: input.currency,
        })
        .first<Record<string, unknown>>();
      if (!batch) {
        const id = randomUUID();
        await trx("savings_interest_accrual_batches").insert({
          id,
          tenant_id: input.tenantId,
          accrual_date: input.accrualDate,
          currency: input.currency,
          batch_reference: `SIA-${input.accrualDate}-${input.currency}`,
          algorithm_version: "SV06-1",
          status: "PROCESSING",
          started_at: this.clock(),
          idempotency_key: input.idempotencyKey,
          request_hash: requestHash,
          correlation_id: input.correlationId,
          attempt_count: 1,
        });
        batch = { id };
      }
      let account = await trx("savings_accounts as a")
        .join("savings_product_versions as v", function () {
          this.on("v.tenant_id", "=", "a.tenant_id").andOn(
            "v.id",
            "=",
            "a.product_version_id",
          );
        })
        .join("savings_product_rates as r", function () {
          this.on("r.tenant_id", "=", "v.tenant_id").andOn(
            "r.product_version_id",
            "=",
            "v.id",
          );
        })
        .where({
          "a.tenant_id": input.tenantId,
          "a.id": input.accountId,
          "a.currency": input.currency,
          "a.status": "ACTIVE",
        })
        .whereIn("a.product_type", ["ORDINARY", "TARGET"])
        .where("r.effective_from", "<=", `${input.accrualDate}T23:59:59.999Z`)
        .where((builder) => {
          builder
            .whereNull("r.effective_to")
            .orWhere(
              "r.effective_to",
              ">",
              `${input.accrualDate}T00:00:00.000Z`,
            );
        })
        .first<Record<string, unknown>>("a.*", {
          annual_rate: "r.interest_rate",
          product_rate_id: "r.id",
          day_count_basis: "v.day_count_basis",
          calculation_method: "v.calculation_method",
        });
      if (!account)
        account = await trx("savings_accounts as a")
          .join("fixed_deposits as f", function () {
            this.on("f.tenant_id", "=", "a.tenant_id").andOn(
              "f.savings_account_id",
              "=",
              "a.id",
            );
          })
          .join("fixed_deposit_rates as r", function () {
            this.on("r.tenant_id", "=", "f.tenant_id").andOn(
              "r.id",
              "=",
              "f.fixed_deposit_rate_id",
            );
          })
          .where({
            "a.tenant_id": input.tenantId,
            "a.id": input.accountId,
            "a.currency": input.currency,
            "a.status": "ACTIVE",
            "a.product_type": "FIXED_DEPOSIT",
            "f.status": "ACTIVE",
          })
          .where("f.start_date", "<=", input.accrualDate)
          .where("f.maturity_date", ">", input.accrualDate)
          .first<Record<string, unknown>>("a.*", {
            annual_rate: "f.interest_rate",
            fixed_deposit_id: "f.id",
            fixed_deposit_rate_id: "r.id",
            calculation_basis_amount: "f.principal_amount",
            day_count_basis: "f.day_count_basis",
          });
      if (account?.fixed_deposit_id)
        account = { ...account, calculation_method: "FIXED" };
      if (!account)
        throw new Error("Eligible savings account and rate not found");
      const days =
        String(account.day_count_basis) === "ACT_ACT" &&
        isLeap(Number(input.accrualDate.slice(0, 4)))
          ? 366
          : String(account.day_count_basis) === "ACT_360"
            ? 360
            : 365;
      const basisAmount = String(
        account.calculation_basis_amount ?? account.current_balance,
      );
      const interest = new Decimal(basisAmount)
        .mul(String(account.annual_rate))
        .div(100)
        .div(days)
        .toDecimalPlaces(12)
        .toFixed(12);
      const id = randomUUID();
      const snapshot = {
        algorithm_version: "SV06-1",
        balance_basis: "LEDGER_PROJECTED_CLOSING",
        day_count_basis: account.day_count_basis,
        days_in_basis: days,
        calculation_method: account.calculation_method,
        annual_rate: account.annual_rate,
        rounding: "HALF_EVEN_AT_PAYMENT",
      };
      await trx("savings_interest_accruals").insert({
        id,
        tenant_id: input.tenantId,
        savings_account_id: input.accountId,
        customer_id: account.customer_id,
        accrual_date: input.accrualDate,
        opening_balance: basisAmount,
        applicable_rate: account.annual_rate,
        interest_amount: interest,
        currency: input.currency,
        product_version_id: account.product_version_id,
        product_rate_id: account.product_rate_id ?? null,
        fixed_deposit_id: account.fixed_deposit_id ?? null,
        fixed_deposit_rate_id: account.fixed_deposit_rate_id ?? null,
        accrual_batch_id: batch.id,
        calculation_basis_amount: basisAmount,
        day_count_basis: account.day_count_basis,
        days_in_basis: days,
        calculation_method: account.calculation_method,
        request_hash: requestHash,
        calculation_snapshot: snapshot,
      });
      if (account.fixed_deposit_id)
        await trx("fixed_deposits")
          .where({ tenant_id: input.tenantId, id: account.fixed_deposit_id })
          .update({
            interest_amount: trx.raw("interest_amount + (?::numeric/100)", [
              interest,
            ]),
            maturity_amount: trx.raw(
              "principal_amount + round((interest_amount + (?::numeric/100))*100)::bigint",
              [interest],
            ),
          });
      await trx("savings_interest_accrual_batches")
        .where({ tenant_id: input.tenantId, id: batch.id })
        .update({
          accounts_processed: trx.raw("accounts_processed+1"),
          total_interest: trx.raw("total_interest+?::numeric", [interest]),
          status: "COMPLETED",
          completed_at: this.clock(),
        });
      return {
        accrualId: id,
        accountId: input.accountId,
        accrualDate: input.accrualDate,
        interestUnroundedMinor: interest,
        currency: input.currency,
        replayed: false,
      };
    });
  }

  public async pay(input: {
    tenantId: string;
    accountId: string;
    periodStart: string;
    periodEnd: string;
    currency: "NGN";
    correlationId: string;
    idempotencyKey: string;
  }) {
    const requestHash = hash({
      accountId: input.accountId,
      periodStart: input.periodStart,
      periodEnd: input.periodEnd,
      currency: input.currency,
    });
    const prepared = await withTenantTransaction(
      this.database,
      input.tenantId,
      async (trx) => {
        const existing = await trx("savings_interest_payments")
          .where({
            tenant_id: input.tenantId,
            idempotency_key: input.idempotencyKey,
          })
          .first<Record<string, unknown>>();
        if (existing) {
          if (existing.request_hash !== requestHash)
            throw new Error("Interest-payment idempotency conflict");
          return { payment: existing, account: null, allocations: [] };
        }
        const account = await trx("savings_accounts")
          .where({
            tenant_id: input.tenantId,
            id: input.accountId,
            currency: input.currency,
            status: "ACTIVE",
          })
          .whereIn("product_type", ["ORDINARY", "TARGET"])
          .forUpdate()
          .first<Record<string, unknown>>();
        if (!account) throw new Error("Active savings account not found");
        const accruals = await trx<Record<string, unknown>>(
          "savings_interest_accruals",
        )
          .where({
            tenant_id: input.tenantId,
            savings_account_id: input.accountId,
            posted: false,
          })
          .whereBetween("accrual_date", [input.periodStart, input.periodEnd])
          .orderBy("accrual_date")
          .forUpdate();
        if (accruals.length === 0)
          throw new Error("No unpaid interest accruals found");
        const total = accruals.reduce(
          (sum, row) => sum.plus(String(row.interest_amount)),
          new Decimal(0),
        );
        const amount = total
          .toDecimalPlaces(0, Decimal.ROUND_HALF_EVEN)
          .toFixed(0);
        const allocations = accruals.map((row) => ({
          row,
          minor: new Decimal(String(row.interest_amount))
            .toDecimalPlaces(0, Decimal.ROUND_HALF_EVEN)
            .toFixed(0),
        }));
        const allocated = allocations.reduce(
          (sum, item) => sum + BigInt(item.minor),
          0n,
        );
        const residual = (BigInt(amount) - allocated).toString();
        let batch = await trx("savings_interest_payment_batches")
          .where({
            tenant_id: input.tenantId,
            period_start: input.periodStart,
            period_end: input.periodEnd,
            currency: input.currency,
          })
          .first<Record<string, unknown>>();
        if (!batch) {
          const id = randomUUID();
          await trx("savings_interest_payment_batches").insert({
            id,
            tenant_id: input.tenantId,
            batch_reference: `SIP-${input.periodStart}-${input.periodEnd}-${input.currency}`,
            currency: input.currency,
            period_start: input.periodStart,
            period_end: input.periodEnd,
            status: "PROCESSING",
            started_at: this.clock(),
            idempotency_key: input.idempotencyKey,
            request_hash: requestHash,
            correlation_id: input.correlationId,
            attempt_count: 1,
          });
          batch = { id };
        }
        const id = randomUUID();
        await trx("savings_interest_payments").insert({
          id,
          tenant_id: input.tenantId,
          savings_account_id: input.accountId,
          customer_id: account.customer_id,
          payment_reference: `SIP-${id}`,
          amount,
          currency: input.currency,
          payment_period_start: input.periodStart,
          payment_period_end: input.periodEnd,
          status: "PENDING",
          tax_amount: "0",
          settlement_basis: "ACCRUED",
          payment_batch_id: batch.id,
          rounding_adjustment: residual,
          operation_id: randomUUID(),
          idempotency_key: input.idempotencyKey,
          correlation_id: input.correlationId,
          request_hash: requestHash,
          calculation_snapshot: {
            total_unrounded_minor: total.toFixed(12),
            allocation_rounding: "HALF_EVEN",
            residual_minor: residual,
          },
        });
        for (const item of allocations)
          await trx("savings_interest_payment_accruals").insert({
            tenant_id: input.tenantId,
            interest_payment_id: id,
            interest_accrual_id: item.row.id,
            allocated_unrounded: item.row.interest_amount,
            allocated_minor: item.minor,
          });
        return {
          payment: {
            id,
            amount,
            rounding_adjustment: residual,
            status: "PENDING",
          },
          account,
          allocations,
          batch,
        };
      },
    );
    if (!prepared.account && prepared.payment.status === "SUCCESSFUL")
      return this.paymentResult(prepared.payment, true);
    const account =
      prepared.account ??
      (await withTenantTransaction(this.database, input.tenantId, (trx) =>
        trx("savings_accounts")
          .where({ tenant_id: input.tenantId, id: input.accountId })
          .first<Record<string, unknown>>(),
      ));
    if (!account) throw new Error("Savings account not found");
    const expense = await this.ledger.provisionAccount({
      tenantId: input.tenantId,
      customerId: input.tenantId,
      ownerType: "TENANT",
      accountType: "EXPENSE",
      purpose: "SAVINGS_INTEREST_EXPENSE",
      currency: input.currency,
      idempotencyKey: `interest:${input.idempotencyKey}:expense`,
    });
    const ledgerHash = hash({
      expense: expense.accountId,
      savings: account.ledger_account_id,
      amount: prepared.payment.amount,
      currency: input.currency,
    });
    if (!this.ledger.postInterestPayment)
      throw new Error("Ledger interest-payment capability is unavailable");
    const posting = await this.ledger.postInterestPayment({
      tenantId: input.tenantId,
      interestExpenseAccountId: expense.accountId,
      savingsAccountId: String(account.ledger_account_id),
      amountMinor: String(prepared.payment.amount),
      currency: input.currency,
      reference: `INTEREST-${String(prepared.payment.id)}`,
      idempotencyKey: `interest:${input.idempotencyKey}:posting`,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      await trx("savings_interest_accruals")
        .whereIn(
          "id",
          prepared.allocations.map((item) => scalarString(item.row.id)),
        )
        .andWhere({ tenant_id: input.tenantId })
        .update({
          posted: true,
          posted_at: this.clock(),
          ledger_transaction_id: posting.transactionId,
        });
      await trx("savings_interest_payments")
        .where({ tenant_id: input.tenantId, id: prepared.payment.id })
        .update({
          status: "SUCCESSFUL",
          ledger_transaction_id: posting.transactionId,
          ledger_journal_id: posting.journalId,
          ledger_request_hash: ledgerHash,
          ledger_posted_at: this.clock(),
          interest_expense_account_id: expense.accountId,
          paid_at: this.clock(),
        });
      await trx("savings_interest_payment_batches")
        .where({ tenant_id: input.tenantId, id: prepared.batch?.id })
        .update({
          status: "COMPLETED",
          payments_processed: trx.raw("payments_processed+1"),
          total_paid_minor: trx.raw("total_paid_minor+?::bigint", [
            scalarString(prepared.payment.amount),
          ]),
          completed_at: this.clock(),
        });
      await trx("savings_outbox_events").insert({
        tenant_id: input.tenantId,
        aggregate_type: "interest_payment",
        aggregate_id: prepared.payment.id,
        aggregate_version: 1,
        event_type: "savings.interest-posted.v1",
        event_version: 1,
        correlation_id: input.correlationId,
        request_id: input.idempotencyKey,
        partition_key: `${input.tenantId}:interest_payment:${String(prepared.payment.id)}`,
        payload: {
          interest_payment_id: prepared.payment.id,
          savings_account_id: input.accountId,
          ledger_transaction_id: posting.transactionId,
          amount_minor: prepared.payment.amount,
          rounding_residual_minor: prepared.payment.rounding_adjustment,
          currency: input.currency,
          period_start: input.periodStart,
          period_end: input.periodEnd,
        },
      });
      const saved = await trx("savings_interest_payments")
        .where({ tenant_id: input.tenantId, id: prepared.payment.id })
        .first<Record<string, unknown>>();
      if (!saved)
        throw new Error("Successful interest payment was not persisted");
      return this.paymentResult(saved, false);
    });
  }

  private accrualResult(
    row: Record<string, unknown>,
    hashValue: string,
    replayed: boolean,
  ) {
    if (row.request_hash !== hashValue)
      throw new Error("Interest-accrual conflict");
    return {
      accrualId: String(row.id),
      accountId: String(row.savings_account_id),
      accrualDate: dateOnly(row.accrual_date),
      interestUnroundedMinor: String(row.interest_amount),
      currency: "NGN" as const,
      replayed,
    };
  }
  private paymentResult(row: Record<string, unknown>, replayed: boolean) {
    return {
      interestPaymentId: String(row.id),
      accountId: String(row.savings_account_id),
      amountMinor: String(row.amount),
      roundingResidualMinor: String(row.rounding_adjustment),
      ledgerTransactionId: String(row.ledger_transaction_id),
      currency: "NGN" as const,
      status: "SUCCESSFUL" as const,
      replayed,
    };
  }
}
function hash(value: unknown) {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}
function dateOnly(value: unknown) {
  if (!(value instanceof Date)) return String(value).slice(0, 10);
  return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, "0")}-${String(value.getDate()).padStart(2, "0")}`;
}
function isLeap(year: number) {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}
function scalarString(value: unknown): string {
  if (
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "bigint"
  )
    return String(value);
  throw new Error("Expected scalar database value");
}
