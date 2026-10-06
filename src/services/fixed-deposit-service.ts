import { createHash, randomUUID } from "node:crypto";
import { Decimal } from "decimal.js";
import type { Knex } from "knex";
import { withTenantTransaction } from "../database/client.js";
import type { SavingsLedgerGateway } from "./ledger-gateway.js";

type Terms = {
  minimumTenureDays: number;
  maximumTenureDays: number;
  earlyLiquidationPenaltyRate: string;
  earlyWithdrawalAllowed: true;
};

export class FixedDepositService {
  public constructor(
    private readonly database: Knex,
    private readonly ledger: SavingsLedgerGateway,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  public async quotePlacement(input: {
    tenantId: string;
    customerId: string;
    productVersionId: string;
    principalMinor: string;
    currency: "NGN";
    tenureDays: number;
    correlationId: string;
    idempotencyKey: string;
  }) {
    const requestHash = hash({
      customerId: input.customerId,
      productVersionId: input.productVersionId,
      principalMinor: input.principalMinor,
      currency: input.currency,
      tenureDays: input.tenureDays,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      const existing = await trx("fixed_deposit_quotes")
        .where({
          tenant_id: input.tenantId,
          idempotency_key: input.idempotencyKey,
        })
        .first<Record<string, unknown>>();
      if (existing) return this.quoteResult(existing, requestHash, true);
      const version = await trx("savings_product_versions")
        .where({
          tenant_id: input.tenantId,
          id: input.productVersionId,
          product_type: "FIXED_DEPOSIT",
          status: "PUBLISHED",
          is_current: true,
          currency: input.currency,
        })
        .where("effective_from", "<=", trx.fn.now())
        .first<{
          annual_rate: string;
          minimum_deposit: string;
          maximum_balance: string | null;
          terms: Terms;
        }>();
      if (!version)
        throw new Error(
          "Current published fixed-deposit product version not found",
        );
      if (
        input.tenureDays < version.terms.minimumTenureDays ||
        input.tenureDays > version.terms.maximumTenureDays
      )
        throw new Error("Fixed-deposit tenure is outside product terms");
      if (
        BigInt(input.principalMinor) < BigInt(version.minimum_deposit) ||
        (version.maximum_balance !== null &&
          BigInt(input.principalMinor) > BigInt(version.maximum_balance))
      )
        throw new Error("Fixed-deposit amount is outside product terms");
      const unrounded = new Decimal(input.principalMinor)
        .mul(version.annual_rate)
        .mul(input.tenureDays)
        .div(100)
        .div(365);
      const interestMinor = unrounded
        .toDecimalPlaces(0, Decimal.ROUND_HALF_EVEN)
        .toFixed(0);
      const payoutMinor = (
        BigInt(input.principalMinor) + BigInt(interestMinor)
      ).toString();
      const id = randomUUID();
      const expiresAt = new Date(this.clock().getTime() + 10 * 60_000);
      const quoteHash = hash({
        id,
        productVersionId: input.productVersionId,
        principalMinor: input.principalMinor,
        interestRate: version.annual_rate,
        tenureDays: input.tenureDays,
        expectedInterestMinor: interestMinor,
        payoutMinor,
        currency: input.currency,
        expiresAt: expiresAt.toISOString(),
      });
      const row = {
        id,
        tenant_id: input.tenantId,
        customer_id: input.customerId,
        quote_type: "PLACEMENT",
        product_version_id: input.productVersionId,
        principal_minor: input.principalMinor,
        currency: input.currency,
        tenure_days: input.tenureDays,
        interest_rate: version.annual_rate,
        expected_interest_unrounded: unrounded.toDecimalPlaces(12).toFixed(12),
        expected_interest_minor: interestMinor,
        penalty_minor: "0",
        payout_minor: payoutMinor,
        calculation_snapshot: {
          day_count_basis: "ACT_365_FIXED",
          rounding: "HALF_EVEN",
        },
        quote_hash: quoteHash,
        request_hash: requestHash,
        idempotency_key: input.idempotencyKey,
        expires_at: expiresAt,
        created_at: this.clock(),
        correlation_id: input.correlationId,
      };
      await trx("fixed_deposit_quotes").insert(row);
      return this.quoteResult(row, requestHash, false);
    });
  }

  public async quoteLiquidation(input: {
    tenantId: string;
    customerId: string;
    fixedDepositId: string;
    currency: "NGN";
    correlationId: string;
    idempotencyKey: string;
    previousFixedDepositId?: string;
  }) {
    const requestHash = hash({
      customerId: input.customerId,
      fixedDepositId: input.fixedDepositId,
      currency: input.currency,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      const existing = await trx("fixed_deposit_quotes")
        .where({
          tenant_id: input.tenantId,
          idempotency_key: input.idempotencyKey,
        })
        .first<Record<string, unknown>>();
      if (existing) return this.quoteResult(existing, requestHash, true);
      const deposit = await trx("fixed_deposits")
        .where({
          tenant_id: input.tenantId,
          id: input.fixedDepositId,
          customer_id: input.customerId,
          currency: input.currency,
          status: "ACTIVE",
          early_liquidation_allowed: true,
        })
        .first<Record<string, unknown>>();
      if (!deposit) throw new Error("Liquidatable fixed deposit not found");
      if (
        this.clock().toISOString().slice(0, 10) >=
        dateOnly(deposit.maturity_date)
      )
        throw new Error("Matured fixed deposit cannot be liquidated");
      const interestMinor = new Decimal(String(deposit.interest_amount))
        .mul(100)
        .toDecimalPlaces(0, Decimal.ROUND_HALF_EVEN)
        .toFixed(0);
      const penaltyMinor = new Decimal(String(deposit.principal_amount))
        .mul(String(deposit.early_liquidation_penalty_rate))
        .div(100)
        .toDecimalPlaces(0, Decimal.ROUND_HALF_EVEN)
        .toFixed(0);
      const payoutMinor = (
        BigInt(String(deposit.principal_amount)) +
        BigInt(interestMinor) -
        BigInt(penaltyMinor)
      ).toString();
      const id = randomUUID();
      const expiresAt = new Date(this.clock().getTime() + 10 * 60_000);
      const quoteHash = hash({
        id,
        fixedDepositId: input.fixedDepositId,
        principalMinor: deposit.principal_amount,
        interestMinor,
        penaltyMinor,
        payoutMinor,
        currency: input.currency,
        expiresAt: expiresAt.toISOString(),
      });
      const row = {
        id,
        tenant_id: input.tenantId,
        customer_id: input.customerId,
        quote_type: "LIQUIDATION",
        fixed_deposit_id: input.fixedDepositId,
        product_version_id: deposit.product_version_id,
        principal_minor: deposit.principal_amount,
        currency: input.currency,
        tenure_days: deposit.tenure_days,
        interest_rate: deposit.interest_rate,
        expected_interest_unrounded: deposit.interest_amount,
        expected_interest_minor: interestMinor,
        penalty_minor: penaltyMinor,
        payout_minor: payoutMinor,
        calculation_snapshot: {
          penalty_rate: deposit.early_liquidation_penalty_rate,
          rounding: "HALF_EVEN",
        },
        quote_hash: quoteHash,
        request_hash: requestHash,
        idempotency_key: input.idempotencyKey,
        expires_at: expiresAt,
        created_at: this.clock(),
        correlation_id: input.correlationId,
      };
      await trx("fixed_deposit_quotes").insert(row);
      return this.quoteResult(row, requestHash, false);
    });
  }

  public async get(input: {
    tenantId: string;
    customerId: string;
    fixedDepositId: string;
  }) {
    const row = await withTenantTransaction(
      this.database,
      input.tenantId,
      (trx) =>
        trx("fixed_deposits as f")
          .leftJoin("fixed_deposit_instructions as i", function () {
            this.on("i.tenant_id", "=", "f.tenant_id")
              .andOn("i.fixed_deposit_id", "=", "f.id")
              .andOnNull("i.superseded_at");
          })
          .where({
            "f.tenant_id": input.tenantId,
            "f.id": input.fixedDepositId,
            "f.customer_id": input.customerId,
          })
          .first<Record<string, unknown>>("f.*", {
            maturity_action: "i.maturity_action",
          }),
    );
    if (!row) throw new Error("Fixed deposit not found");
    return {
      fixedDepositId: String(row.id),
      productVersionId: String(row.product_version_id),
      principalMinor: String(row.principal_amount),
      interestRate: String(row.interest_rate),
      accruedInterest: String(row.interest_amount),
      tenureDays: Number(row.tenure_days),
      startDate: dateOnly(row.start_date),
      maturityDate: dateOnly(row.maturity_date),
      currency: "NGN" as const,
      status: String(row.status),
      maturityInstruction: row.maturity_action
        ? scalarString(row.maturity_action).toLowerCase()
        : "payout",
    };
  }

  public async create(input: {
    tenantId: string;
    customerId: string;
    productVersionId: string;
    amountMinor: string;
    currency: "NGN";
    tenureDays: number;
    quoteId: string;
    quoteHash: string;
    acceptedAt: string;
    acceptanceReference: string;
    correlationId: string;
    idempotencyKey: string;
    previousFixedDepositId?: string;
  }) {
    const requestHash = hash({
      customerId: input.customerId,
      productVersionId: input.productVersionId,
      amountMinor: input.amountMinor,
      currency: input.currency,
      tenureDays: input.tenureDays,
      acceptedAt: input.acceptedAt,
      acceptanceReference: input.acceptanceReference,
      quoteId: input.quoteId,
      quoteHash: input.quoteHash,
    });
    const prior = await withTenantTransaction(
      this.database,
      input.tenantId,
      (trx) =>
        trx("fixed_deposits")
          .where({
            tenant_id: input.tenantId,
            placement_idempotency_key: input.idempotencyKey,
          })
          .first<Record<string, unknown>>(),
    );
    if (prior) return this.created(prior, requestHash, true);
    const quote = await withTenantTransaction(
      this.database,
      input.tenantId,
      (trx) =>
        trx("fixed_deposit_quotes")
          .where({
            tenant_id: input.tenantId,
            id: input.quoteId,
            customer_id: input.customerId,
            quote_type: "PLACEMENT",
            product_version_id: input.productVersionId,
            principal_minor: input.amountMinor,
            currency: input.currency,
            tenure_days: input.tenureDays,
            quote_hash: input.quoteHash,
          })
          .whereNull("consumed_at")
          .where("expires_at", ">", this.clock())
          .first<Record<string, unknown>>(),
    );
    if (!quote)
      throw new Error("Valid unconsumed fixed-deposit quote not found");
    const version = await withTenantTransaction(
      this.database,
      input.tenantId,
      (trx) =>
        trx("savings_product_versions as v")
          .join("fixed_deposit_rates as r", function () {
            this.on("r.tenant_id", "=", "v.tenant_id").andOn(
              "r.product_version_id",
              "=",
              "v.id",
            );
          })
          .where({
            "v.tenant_id": input.tenantId,
            "v.id": input.productVersionId,
            "v.product_type": "FIXED_DEPOSIT",
            "v.status": "PUBLISHED",
            "v.is_current": true,
            "v.currency": input.currency,
          })
          .where("v.effective_from", "<=", trx.fn.now())
          .first<{
            savings_product_id: string;
            annual_rate: string;
            minimum_deposit: string;
            maximum_balance: string | null;
            terms: Terms;
            terms_hash: string;
            rate_id: string;
            day_count_basis: string;
            compounding_method: string;
          }>({
            savings_product_id: "v.savings_product_id",
            annual_rate: "v.annual_rate",
            minimum_deposit: "v.minimum_deposit",
            maximum_balance: "v.maximum_balance",
            terms: "v.terms",
            terms_hash: "v.terms_hash",
            rate_id: "r.id",
            day_count_basis: "v.day_count_basis",
            compounding_method: "v.compounding_method",
          }),
    );
    if (!version)
      throw new Error(
        "Current published fixed-deposit product version not found",
      );
    if (
      input.tenureDays < version.terms.minimumTenureDays ||
      input.tenureDays > version.terms.maximumTenureDays
    )
      throw new Error("Fixed-deposit tenure is outside product terms");
    if (
      BigInt(input.amountMinor) < BigInt(version.minimum_deposit) ||
      (version.maximum_balance !== null &&
        BigInt(input.amountMinor) > BigInt(version.maximum_balance))
    )
      throw new Error("Fixed-deposit amount is outside product terms");
    const fixedLedger = await this.ledger.provisionAccount({
      tenantId: input.tenantId,
      customerId: input.customerId,
      purpose: "FIXED_DEPOSIT",
      currency: input.currency,
      idempotencyKey: `fd:${input.idempotencyKey}:account`,
    });
    const wallet = await this.ledger.provisionAccount({
      tenantId: input.tenantId,
      customerId: input.customerId,
      purpose: "WALLET",
      currency: input.currency,
      idempotencyKey: `fd:${input.idempotencyKey}:wallet`,
    });
    const postingHash = hash({
      wallet: wallet.accountId,
      fixed: fixedLedger.accountId,
      amountMinor: input.amountMinor,
      currency: input.currency,
    });
    const posting = await this.ledger.postContribution({
      tenantId: input.tenantId,
      walletAccountId: wallet.accountId,
      savingsAccountId: fixedLedger.accountId,
      amountMinor: input.amountMinor,
      currency: input.currency,
      reference: `FD-${input.idempotencyKey}`,
      idempotencyKey: `fd:${input.idempotencyKey}:posting`,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      const replay = await trx("fixed_deposits")
        .where({
          tenant_id: input.tenantId,
          placement_idempotency_key: input.idempotencyKey,
        })
        .first<Record<string, unknown>>();
      if (replay) return this.created(replay, requestHash, true);
      const sequence = (
        await trx.raw<{ rows: Array<{ value: string }> }>(
          "SELECT nextval(pg_get_serial_sequence('savings_accounts','opening_sequence'))::text AS value",
        )
      ).rows[0]?.value;
      if (!sequence)
        throw new Error("Could not allocate fixed-deposit account number");
      const accountId = randomUUID();
      const id = randomUUID();
      const startDate = this.clock();
      const maturity = new Date(startDate);
      maturity.setUTCDate(maturity.getUTCDate() + input.tenureDays);
      await trx("savings_accounts").insert({
        id: accountId,
        tenant_id: input.tenantId,
        customer_id: input.customerId,
        savings_product_id: version.savings_product_id,
        product_version_id: input.productVersionId,
        product_type: "FIXED_DEPOSIT",
        account_number: `SFD${sequence.padStart(12, "0")}`,
        currency: input.currency,
        status: "ACTIVE",
        current_balance: "0",
        total_deposited: "0",
        ledger_account_id: fixedLedger.accountId,
        opened_at: trx.fn.now(),
        opening_sequence: sequence,
        opening_idempotency_key: `fd:${input.idempotencyKey}`,
        opening_request_hash: requestHash,
        created_by: input.customerId,
      });
      await trx("savings_account_holders").insert({
        tenant_id: input.tenantId,
        savings_account_id: accountId,
        customer_id: input.customerId,
        role: "PRIMARY",
        mandate_role: "OWNER",
        consent_reference: input.acceptanceReference,
      });
      await trx("savings_account_contracts").insert({
        tenant_id: input.tenantId,
        savings_account_id: accountId,
        product_version_id: input.productVersionId,
        customer_id: input.customerId,
        contract_reference: input.acceptanceReference,
        accepted_at: input.acceptedAt,
        terms_hash: version.terms_hash,
        acceptance_evidence: {
          source: "CUSTOMER_API",
          correlation_id: input.correlationId,
        },
      });
      await trx("savings_account_status_history").insert({
        tenant_id: input.tenantId,
        savings_account_id: accountId,
        previous_status: null,
        new_status: "ACTIVE",
        reason_code: "FIXED_DEPOSIT_PLACED",
        source: "CUSTOMER",
        changed_by: input.customerId,
        request_id: input.idempotencyKey,
        correlation_id: input.correlationId,
      });
      await trx("fixed_deposits").insert({
        id,
        tenant_id: input.tenantId,
        savings_account_id: accountId,
        customer_id: input.customerId,
        deposit_reference: `SFD-${id}`,
        principal_amount: input.amountMinor,
        currency: input.currency,
        interest_rate: version.annual_rate,
        tenure_days: input.tenureDays,
        start_date: startDate.toISOString().slice(0, 10),
        maturity_date: maturity.toISOString().slice(0, 10),
        interest_amount: "0",
        maturity_amount: input.amountMinor,
        status: "ACTIVE",
        source_account_id: wallet.accountId,
        destination_account_id: wallet.accountId,
        ledger_transaction_id: posting.transactionId,
        ledger_journal_id: posting.journalId,
        ledger_request_hash: postingHash,
        ledger_posted_at: trx.fn.now(),
        product_version_id: input.productVersionId,
        fixed_deposit_rate_id: version.rate_id,
        contract_reference: input.acceptanceReference,
        accepted_at: input.acceptedAt,
        accepted_terms_hash: version.terms_hash,
        terms_snapshot: version.terms,
        day_count_basis: version.day_count_basis,
        compounding_method: version.compounding_method,
        placement_idempotency_key: input.idempotencyKey,
        placement_request_hash: requestHash,
        correlation_id: input.correlationId,
        early_liquidation_allowed: version.terms.earlyWithdrawalAllowed,
        early_liquidation_penalty_rate:
          version.terms.earlyLiquidationPenaltyRate,
        quote_id: input.quoteId,
        quote_hash: input.quoteHash,
        quote_expires_at: quote.expires_at,
        created_by: input.customerId,
        previous_fixed_deposit_id: input.previousFixedDepositId ?? null,
      });
      await trx("savings_accounts")
        .where({ tenant_id: input.tenantId, id: accountId })
        .update({
          current_balance: input.amountMinor,
          total_deposited: input.amountMinor,
          ledger_synced_at: trx.fn.now(),
        });
      await trx("fixed_deposit_quotes")
        .where({ tenant_id: input.tenantId, id: input.quoteId })
        .whereNull("consumed_at")
        .update({ consumed_at: this.clock() });
      await this.event(trx, input, id, "savings.fixed-deposit-created.v1", {
        fixed_deposit_id: id,
        customer_id: input.customerId,
        product_version_id: input.productVersionId,
        principal_minor: input.amountMinor,
        currency: input.currency,
        maturity_date: maturity.toISOString().slice(0, 10),
      });
      return {
        fixedDepositId: id,
        principalMinor: input.amountMinor,
        interestRate: version.annual_rate,
        maturityDate: maturity.toISOString().slice(0, 10),
        currency: input.currency,
        status: "ACTIVE" as const,
        ledgerTransactionId: posting.transactionId,
        replayed: false,
      };
    });
  }

  public async liquidate(input: {
    tenantId: string;
    customerId: string;
    fixedDepositId: string;
    quoteId: string;
    quoteHash: string;
    currency: "NGN";
    correlationId: string;
    idempotencyKey: string;
  }) {
    return this.settle("LIQUIDATED", input);
  }

  public async setMaturityInstruction(input: {
    tenantId: string;
    customerId: string;
    fixedDepositId: string;
    instruction:
      "PAYOUT_ALL" | "RENEW_PRINCIPAL" | "RENEW_PRINCIPAL_AND_INTEREST";
    renewalTenureDays?: number;
    currency: "NGN";
    correlationId: string;
    idempotencyKey: string;
  }) {
    const requestHash = hash({
      customerId: input.customerId,
      fixedDepositId: input.fixedDepositId,
      instruction: input.instruction,
      renewalTenureDays: input.renewalTenureDays ?? null,
      currency: input.currency,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      const replay = await trx("fixed_deposit_instructions")
        .where({
          tenant_id: input.tenantId,
          idempotency_key: input.idempotencyKey,
        })
        .first<Record<string, unknown>>();
      if (replay) {
        if (replay.request_hash !== requestHash)
          throw new Error("Maturity-instruction idempotency conflict");
        return {
          instructionId: String(replay.id),
          instruction: String(replay.maturity_action),
          replayed: true,
        };
      }
      const deposit = await trx("fixed_deposits")
        .where({
          tenant_id: input.tenantId,
          id: input.fixedDepositId,
          customer_id: input.customerId,
          currency: input.currency,
          status: "ACTIVE",
        })
        .forUpdate()
        .first<Record<string, unknown>>();
      if (!deposit) throw new Error("Active fixed deposit not found");
      const cutoff = new Date(
        `${dateOnly(deposit.maturity_date)}T00:00:00.000Z`,
      );
      cutoff.setUTCDate(
        cutoff.getUTCDate() - Number(deposit.maturity_instruction_cutoff_days),
      );
      if (this.clock() >= cutoff)
        throw new Error("Maturity-instruction cutoff has passed");
      if (
        input.instruction !== "PAYOUT_ALL" &&
        (!input.renewalTenureDays || input.renewalTenureDays <= 0)
      )
        throw new Error("Renewal instruction requires renewal_tenure_days");
      const current = await trx("fixed_deposit_instructions")
        .where({
          tenant_id: input.tenantId,
          fixed_deposit_id: input.fixedDepositId,
        })
        .whereNull("superseded_at")
        .forUpdate()
        .first<{ instruction_number: number }>();
      if (current)
        await trx("fixed_deposit_instructions")
          .where({
            tenant_id: input.tenantId,
            fixed_deposit_id: input.fixedDepositId,
          })
          .whereNull("superseded_at")
          .update({ superseded_at: trx.fn.now() });
      const id = randomUUID();
      await trx("fixed_deposit_instructions").insert({
        id,
        tenant_id: input.tenantId,
        fixed_deposit_id: input.fixedDepositId,
        instruction_number: (current?.instruction_number ?? 0) + 1,
        maturity_action: input.instruction,
        renewal_tenure_days:
          input.instruction === "PAYOUT_ALL" ? null : input.renewalTenureDays,
        destination_account_id: deposit.destination_account_id,
        accepted_at: trx.fn.now(),
        consent_reference: input.idempotencyKey,
        idempotency_key: input.idempotencyKey,
        request_hash: requestHash,
        correlation_id: input.correlationId,
      });
      return {
        instructionId: id,
        instruction: input.instruction,
        replayed: false,
      };
    });
  }
  public async mature(input: {
    tenantId: string;
    customerId: string;
    fixedDepositId: string;
    currency: "NGN";
    correlationId: string;
    idempotencyKey: string;
  }) {
    const priorMaturity = await withTenantTransaction(
      this.database,
      input.tenantId,
      (trx) =>
        trx("fixed_deposit_maturities")
          .where({
            tenant_id: input.tenantId,
            idempotency_key: input.idempotencyKey,
            fixed_deposit_id: input.fixedDepositId,
          })
          .first<Record<string, unknown>>(),
    );
    if (priorMaturity?.status === "SUCCESSFUL") {
      const priorRenewal = await withTenantTransaction(
        this.database,
        input.tenantId,
        (trx) =>
          trx("fixed_deposit_renewals as r")
            .join("fixed_deposits as f", function () {
              this.on("f.tenant_id", "=", "r.tenant_id").andOn(
                "f.id",
                "=",
                "r.renewed_fixed_deposit_id",
              );
            })
            .where({
              "r.tenant_id": input.tenantId,
              "r.fixed_deposit_id": input.fixedDepositId,
            })
            .first<Record<string, unknown>>("r.*", {
              renewed_maturity_date: "f.maturity_date",
            }),
      );
      return priorRenewal
        ? this.renewedResult(priorRenewal, true)
        : this.settled("MATURED", priorMaturity, true);
    }
    const state = await withTenantTransaction(
      this.database,
      input.tenantId,
      async (trx) => {
        const renewal = await trx("fixed_deposit_renewals as r")
          .join("fixed_deposits as f", function () {
            this.on("f.tenant_id", "=", "r.tenant_id").andOn(
              "f.id",
              "=",
              "r.renewed_fixed_deposit_id",
            );
          })
          .where({
            "r.tenant_id": input.tenantId,
            "r.fixed_deposit_id": input.fixedDepositId,
          })
          .first<Record<string, unknown>>("r.*", {
            renewed_maturity_date: "f.maturity_date",
          });
        if (renewal) return { renewal };
        const deposit = await trx("fixed_deposits")
          .where({
            tenant_id: input.tenantId,
            id: input.fixedDepositId,
            customer_id: input.customerId,
            currency: input.currency,
            status: "ACTIVE",
          })
          .first<Record<string, unknown>>();
        if (!deposit) throw new Error("Active fixed deposit not found");
        const instruction = await trx("fixed_deposit_instructions")
          .where({
            tenant_id: input.tenantId,
            fixed_deposit_id: input.fixedDepositId,
          })
          .whereNull("superseded_at")
          .first<Record<string, unknown>>();
        return { deposit, instruction };
      },
    );
    if (state.renewal) return this.renewedResult(state.renewal, true);
    if (
      !state.instruction ||
      state.instruction.maturity_action === "PAYOUT_ALL"
    )
      return this.settle("MATURED", input);
    return this.renew(input, state.deposit, state.instruction);
  }

  private async renew(
    input: {
      tenantId: string;
      customerId: string;
      fixedDepositId: string;
      currency: "NGN";
      correlationId: string;
      idempotencyKey: string;
    },
    deposit: Record<string, unknown>,
    instruction: Record<string, unknown>,
  ) {
    const tenureDays = Number(instruction.renewal_tenure_days);
    const interestMinor = new Decimal(String(deposit.interest_amount))
      .mul(100)
      .toDecimalPlaces(0, Decimal.ROUND_HALF_EVEN)
      .toFixed(0);
    const principalMinor =
      instruction.maturity_action === "RENEW_PRINCIPAL_AND_INTEREST"
        ? (
            BigInt(String(deposit.principal_amount)) + BigInt(interestMinor)
          ).toString()
        : String(deposit.principal_amount);
    const renewalVersion = await withTenantTransaction(
      this.database,
      input.tenantId,
      (trx) =>
        trx("savings_product_versions as current")
          .join("savings_product_versions as original", function () {
            this.on("original.tenant_id", "=", "current.tenant_id").andOn(
              "original.savings_product_id",
              "=",
              "current.savings_product_id",
            );
          })
          .where({
            "current.tenant_id": input.tenantId,
            "current.product_type": "FIXED_DEPOSIT",
            "current.status": "PUBLISHED",
            "current.is_current": true,
            "current.currency": input.currency,
            "original.id": deposit.product_version_id,
          })
          .where("current.effective_from", "<=", trx.fn.now())
          .first<{ id: string }>("current.id"),
    );
    if (!renewalVersion)
      throw new Error(
        "Current published fixed-deposit renewal version not found",
      );
    // Validate current published terms before releasing the matured deposit.
    const quote = await this.quotePlacement({
      tenantId: input.tenantId,
      customerId: input.customerId,
      productVersionId: renewalVersion.id,
      principalMinor,
      currency: input.currency,
      tenureDays,
      correlationId: input.correlationId,
      idempotencyKey: `renew:${input.idempotencyKey}:quote`,
    });
    const settlement = await this.settle("RENEWED", input);
    const created = await this.create({
      tenantId: input.tenantId,
      customerId: input.customerId,
      productVersionId: renewalVersion.id,
      amountMinor: principalMinor,
      currency: input.currency,
      tenureDays,
      quoteId: quote.quoteId,
      quoteHash: quote.quoteHash,
      acceptedAt: this.clock().toISOString(),
      acceptanceReference: `MATURITY-INSTRUCTION-${String(instruction.id)}`,
      correlationId: input.correlationId,
      idempotencyKey: `renew:${input.idempotencyKey}:placement`,
      previousFixedDepositId: input.fixedDepositId,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      const existing = await trx("fixed_deposit_renewals")
        .where({
          tenant_id: input.tenantId,
          fixed_deposit_id: input.fixedDepositId,
        })
        .first<Record<string, unknown>>();
      if (existing) return this.renewedResult(existing, true);
      const renewedDeposit = await trx("fixed_deposits")
        .where({
          tenant_id: input.tenantId,
          id: created.fixedDepositId,
          previous_fixed_deposit_id: input.fixedDepositId,
        })
        .first<Record<string, unknown>>();
      if (!renewedDeposit)
        throw new Error("Renewed fixed-deposit chain was not persisted");
      const id = randomUUID();
      await trx("fixed_deposit_renewals").insert({
        id,
        tenant_id: input.tenantId,
        fixed_deposit_id: input.fixedDepositId,
        previous_maturity_date: deposit.maturity_date,
        new_start_date: renewedDeposit.start_date,
        new_maturity_date: renewedDeposit.maturity_date,
        principal_amount: renewedDeposit.principal_amount,
        interest_amount: interestMinor,
        interest_rate: renewedDeposit.interest_rate,
        tenure_days: renewedDeposit.tenure_days,
        renewed_fixed_deposit_id: created.fixedDepositId,
        renewal_instruction_id: instruction.id,
        ledger_transaction_id: created.ledgerTransactionId,
      });
      await this.event(
        trx,
        input,
        input.fixedDepositId,
        "savings.fixed-deposit-renewed.v1",
        {
          fixed_deposit_id: input.fixedDepositId,
          renewed_fixed_deposit_id: created.fixedDepositId,
          principal_minor: principalMinor,
          currency: input.currency,
          maturity_date: created.maturityDate,
        },
        2,
      );
      return {
        ...settlement,
        status: "RENEWED" as const,
        renewedFixedDepositId: created.fixedDepositId,
        renewedPrincipalMinor: principalMinor,
        renewedMaturityDate: created.maturityDate,
        replayed: false,
      };
    });
  }

  private async settle(
    kind: "LIQUIDATED" | "MATURED" | "RENEWED",
    input: {
      tenantId: string;
      customerId: string;
      fixedDepositId: string;
      quoteId?: string;
      quoteHash?: string;
      currency: "NGN";
      correlationId: string;
      idempotencyKey: string;
    },
  ) {
    const requestHash = hash({
      kind,
      customerId: input.customerId,
      fixedDepositId: input.fixedDepositId,
      currency: input.currency,
      quoteId: input.quoteId ?? null,
      quoteHash: input.quoteHash ?? null,
    });
    const table =
      kind === "LIQUIDATED"
        ? "fixed_deposit_liquidations"
        : "fixed_deposit_maturities";
    const prepared = await withTenantTransaction(
      this.database,
      input.tenantId,
      async (trx) => {
        const existing = await trx(table)
          .where({
            tenant_id: input.tenantId,
            idempotency_key: input.idempotencyKey,
          })
          .first<Record<string, unknown>>();
        if (existing) {
          if (existing.request_hash !== requestHash)
            throw new Error("Fixed-deposit settlement idempotency conflict");
          return { operation: existing, deposit: null };
        }
        const deposit = await trx("fixed_deposits as f")
          .join("savings_accounts as a", function () {
            this.on("a.tenant_id", "=", "f.tenant_id").andOn(
              "a.id",
              "=",
              "f.savings_account_id",
            );
          })
          .where({
            "f.tenant_id": input.tenantId,
            "f.id": input.fixedDepositId,
            "f.customer_id": input.customerId,
            "f.currency": input.currency,
            "f.status": "ACTIVE",
          })
          .forUpdate()
          .first<Record<string, unknown>>("f.*", {
            ledger_account_id: "a.ledger_account_id",
          });
        if (!deposit) throw new Error("Active fixed deposit not found");
        let settlementQuote: Record<string, unknown> | undefined;
        if (kind === "LIQUIDATED") {
          settlementQuote = await trx("fixed_deposit_quotes")
            .where({
              tenant_id: input.tenantId,
              id: input.quoteId,
              customer_id: input.customerId,
              quote_type: "LIQUIDATION",
              fixed_deposit_id: input.fixedDepositId,
              quote_hash: input.quoteHash,
            })
            .whereNull("consumed_at")
            .where("expires_at", ">", this.clock())
            .first<Record<string, unknown>>();
          if (!settlementQuote)
            throw new Error("Valid unconsumed liquidation quote not found");
        }
        const today = this.clock().toISOString().slice(0, 10);
        const matured = today >= dateOnly(deposit.maturity_date);
        if (kind === "MATURED" && !matured)
          throw new Error("Fixed deposit has not matured");
        if (kind === "LIQUIDATED" && matured)
          throw new Error("Matured fixed deposit must use maturity processing");
        if (kind === "LIQUIDATED" && deposit.early_liquidation_allowed !== true)
          throw new Error("Early liquidation is disabled");
        const interest = new Decimal(String(deposit.interest_amount))
          .mul(100)
          .toDecimalPlaces(0, Decimal.ROUND_HALF_EVEN)
          .toFixed(0);
        const penalty =
          kind === "LIQUIDATED"
            ? new Decimal(String(deposit.principal_amount))
                .mul(String(deposit.early_liquidation_penalty_rate))
                .div(100)
                .toDecimalPlaces(0, Decimal.ROUND_HALF_EVEN)
                .toFixed(0)
            : "0";
        const id = randomUUID();
        if (kind === "LIQUIDATED")
          await trx(table).insert({
            id,
            tenant_id: input.tenantId,
            fixed_deposit_id: input.fixedDepositId,
            liquidation_reference: `FDL-${id}`,
            status: "POSTING",
            principal_amount: deposit.principal_amount,
            interest_due: interest,
            interest_clawback: "0",
            penalty_amount: penalty,
            tax_amount: "0",
            calculation_snapshot: {
              rounding: "HALF_EVEN",
              interest_unrounded_major: deposit.interest_amount,
              penalty_rate: deposit.early_liquidation_penalty_rate,
            },
            quote_id: input.quoteId,
            quote_hash: input.quoteHash,
            quote_expires_at: settlementQuote?.expires_at,
            destination_account_id: deposit.destination_account_id,
            created_by: input.customerId,
            authority_type: "PRODUCT_POLICY",
            idempotency_key: input.idempotencyKey,
            request_hash: requestHash,
            correlation_id: input.correlationId,
          });
        if (kind === "LIQUIDATED")
          await trx("fixed_deposit_quotes")
            .where({ tenant_id: input.tenantId, id: input.quoteId })
            .whereNull("consumed_at")
            .update({ consumed_at: trx.fn.now() });
        else {
          let instruction = await trx("fixed_deposit_instructions")
            .where({
              tenant_id: input.tenantId,
              fixed_deposit_id: input.fixedDepositId,
            })
            .whereNull("superseded_at")
            .first<{ id: string; maturity_action: string }>();
          if (!instruction) {
            const instructionId = randomUUID();
            await trx("fixed_deposit_instructions").insert({
              id: instructionId,
              tenant_id: input.tenantId,
              fixed_deposit_id: input.fixedDepositId,
              instruction_number: 1,
              maturity_action: "PAYOUT_ALL",
              destination_account_id: deposit.destination_account_id,
              accepted_at: trx.fn.now(),
              consent_reference: "SYSTEM_DEFAULT",
              idempotency_key: `default:${input.fixedDepositId}`,
              request_hash: hash({ action: "PAYOUT_ALL" }),
              correlation_id: input.correlationId,
            });
            instruction = { id: instructionId, maturity_action: "PAYOUT_ALL" };
          }
          if (
            (kind === "MATURED" &&
              instruction.maturity_action !== "PAYOUT_ALL") ||
            (kind === "RENEWED" && instruction.maturity_action === "PAYOUT_ALL")
          )
            throw new Error("Maturity action does not match instruction");
          await trx(table).insert({
            id,
            tenant_id: input.tenantId,
            fixed_deposit_id: input.fixedDepositId,
            instruction_id: instruction.id,
            maturity_reference: `FDM-${id}`,
            status: "PENDING",
            principal_amount: deposit.principal_amount,
            unpaid_interest: interest,
            tax_amount: "0",
            idempotency_key: input.idempotencyKey,
            request_hash: requestHash,
            correlation_id: input.correlationId,
          });
        }
        return {
          operation: {
            id,
            principal_amount: deposit.principal_amount,
            interest_due: interest,
            unpaid_interest: interest,
            penalty_amount: penalty,
            status: "POSTING",
          },
          deposit,
        };
      },
    );
    if (!prepared.deposit && prepared.operation.status === "SUCCESSFUL")
      return this.settled(kind, prepared.operation, true);
    const deposit =
      prepared.deposit ??
      (await withTenantTransaction(this.database, input.tenantId, (trx) =>
        trx("fixed_deposits as f")
          .join("savings_accounts as a", function () {
            this.on("a.tenant_id", "=", "f.tenant_id").andOn(
              "a.id",
              "=",
              "f.savings_account_id",
            );
          })
          .where({
            "f.tenant_id": input.tenantId,
            "f.id": input.fixedDepositId,
          })
          .first<Record<string, unknown>>("f.*", {
            ledger_account_id: "a.ledger_account_id",
          }),
      ));
    if (!deposit) throw new Error("Fixed deposit not found");
    const wallet = await this.ledger.provisionAccount({
      tenantId: input.tenantId,
      customerId: input.customerId,
      purpose: "WALLET",
      currency: input.currency,
      idempotencyKey: `fd-settle:${input.idempotencyKey}:wallet`,
    });
    const expense = await this.ledger.provisionAccount({
      tenantId: input.tenantId,
      customerId: input.tenantId,
      ownerType: "TENANT",
      accountType: "EXPENSE",
      purpose: "SAVINGS_INTEREST_EXPENSE",
      currency: input.currency,
      idempotencyKey: `fd-settle:${input.idempotencyKey}:expense`,
    });
    const income = await this.ledger.provisionAccount({
      tenantId: input.tenantId,
      customerId: input.tenantId,
      ownerType: "TENANT",
      accountType: "REVENUE",
      purpose: "SAVINGS_PENALTY_INCOME",
      currency: input.currency,
      idempotencyKey: `fd-settle:${input.idempotencyKey}:income`,
    });
    const interest = String(
      prepared.operation.interest_due ?? prepared.operation.unpaid_interest,
    );
    const penalty = scalarString(prepared.operation.penalty_amount ?? "0");
    const ledgerHash = hash({
      fixed: deposit.ledger_account_id,
      wallet: wallet.accountId,
      principal: prepared.operation.principal_amount,
      interest,
      penalty,
      currency: input.currency,
    });
    const posting = await this.ledger.postFixedDepositSettlement({
      tenantId: input.tenantId,
      fixedDepositAccountId: String(deposit.ledger_account_id),
      walletAccountId: wallet.accountId,
      interestExpenseAccountId: expense.accountId,
      penaltyIncomeAccountId: income.accountId,
      principalMinor: String(prepared.operation.principal_amount),
      interestMinor: interest,
      penaltyMinor: penalty,
      currency: input.currency,
      reference: `${kind}-${scalarString(prepared.operation.id)}`,
      idempotencyKey: `fd-settle:${input.idempotencyKey}:posting`,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      await trx(table)
        .where({ tenant_id: input.tenantId, id: prepared.operation.id })
        .update({
          status: "SUCCESSFUL",
          ledger_transaction_id: posting.transactionId,
          ledger_journal_id: posting.journalId,
          ledger_request_hash: ledgerHash,
          ledger_posted_at: trx.fn.now(),
          processed_at: trx.fn.now(),
        });
      await trx("fixed_deposits")
        .where({
          tenant_id: input.tenantId,
          id: input.fixedDepositId,
          status: "ACTIVE",
        })
        .update({
          status: kind,
          ...(kind !== "LIQUIDATED"
            ? { matured_at: trx.fn.now() }
            : { withdrawn_at: trx.fn.now() }),
        });
      const payload = {
        fixed_deposit_id: input.fixedDepositId,
        principal_minor: String(prepared.operation.principal_amount),
        interest_minor: interest,
        penalty_minor: penalty,
        payout_minor: (
          BigInt(String(prepared.operation.principal_amount)) +
          BigInt(interest) -
          BigInt(penalty)
        ).toString(),
        currency: input.currency,
      };
      if (kind !== "RENEWED")
        await this.event(
          trx,
          input,
          input.fixedDepositId,
          kind === "MATURED"
            ? "savings.fixed-deposit-matured.v1"
            : "savings.fixed-deposit-liquidated.v1",
          payload,
          2,
        );
      return {
        ...payload,
        ledgerTransactionId: posting.transactionId,
        status: kind,
        replayed: false,
      };
    });
  }

  private created(
    row: Record<string, unknown>,
    requestHash: string,
    replayed: boolean,
  ) {
    if (row.placement_request_hash !== requestHash)
      throw new Error("Fixed-deposit placement idempotency conflict");
    return {
      fixedDepositId: String(row.id),
      principalMinor: String(row.principal_amount),
      interestRate: String(row.interest_rate),
      maturityDate: String(row.maturity_date),
      currency: "NGN" as const,
      status: "ACTIVE" as const,
      ledgerTransactionId: String(row.ledger_transaction_id),
      replayed,
    };
  }
  private quoteResult(
    row: Record<string, unknown>,
    requestHash: string,
    replayed: boolean,
  ) {
    if (row.request_hash !== requestHash)
      throw new Error("Fixed-deposit quote idempotency conflict");
    return {
      quoteId: String(row.id),
      quoteHash: String(row.quote_hash),
      principalMinor: String(row.principal_minor),
      interestRate: String(row.interest_rate),
      tenureDays: Number(row.tenure_days),
      expectedInterestMinor: String(row.expected_interest_minor),
      penaltyMinor: String(row.penalty_minor),
      payoutMinor: String(row.payout_minor),
      currency: "NGN" as const,
      expiresAt:
        row.expires_at instanceof Date
          ? row.expires_at.toISOString()
          : String(row.expires_at),
      replayed,
    };
  }
  private settled(
    kind: "LIQUIDATED" | "MATURED" | "RENEWED",
    row: Record<string, unknown>,
    replayed: boolean,
  ) {
    const interest = String(row.interest_due ?? row.unpaid_interest);
    const penalty = scalarString(row.penalty_amount ?? "0");
    return {
      fixed_deposit_id: String(row.fixed_deposit_id),
      principal_minor: String(row.principal_amount),
      interest_minor: interest,
      penalty_minor: penalty,
      payout_minor: (
        BigInt(String(row.principal_amount)) +
        BigInt(interest) -
        BigInt(penalty)
      ).toString(),
      currency: "NGN" as const,
      ledgerTransactionId: String(row.ledger_transaction_id),
      status: kind,
      replayed,
    };
  }
  private renewedResult(row: Record<string, unknown>, replayed: boolean) {
    return {
      fixed_deposit_id: String(row.fixed_deposit_id),
      principal_minor: String(row.principal_amount),
      interest_minor: String(row.interest_amount),
      penalty_minor: "0",
      payout_minor: "0",
      currency: "NGN" as const,
      ledgerTransactionId: String(row.ledger_transaction_id),
      status: "RENEWED" as const,
      renewedFixedDepositId: String(row.renewed_fixed_deposit_id),
      renewedPrincipalMinor: String(row.principal_amount),
      renewedMaturityDate: dateOnly(
        row.renewed_maturity_date ?? row.new_maturity_date,
      ),
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
  ) {
    await trx("savings_outbox_events").insert({
      tenant_id: input.tenantId,
      aggregate_type: "fixed_deposit",
      aggregate_id: aggregateId,
      aggregate_version: version,
      event_type: eventType,
      event_version: 1,
      correlation_id: input.correlationId,
      request_id: input.idempotencyKey,
      partition_key: `${input.tenantId}:fixed_deposit:${aggregateId}`,
      payload,
    });
  }
}

function hash(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}
function dateOnly(value: unknown): string {
  if (value instanceof Date) return value.toISOString().slice(0, 10);
  return String(value).slice(0, 10);
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
