import { createHash, randomUUID } from "node:crypto";
import type { Knex } from "knex";
import { withTenantTransaction } from "../database/client.js";
import type { SavingsLedgerGateway } from "./ledger-gateway.js";

export class OrdinarySavingsService {
  public constructor(
    private readonly database: Knex,
    private readonly ledger: SavingsLedgerGateway,
  ) {}

  public async openAccount(input: {
    tenantId: string;
    customerId: string;
    productVersionId: string;
    currency: "NGN";
    acceptedAt: string;
    acceptanceReference: string;
    correlationId: string;
    idempotencyKey: string;
  }): Promise<{
    id: string;
    productVersionId: string;
    accountNumber: string;
    currency: "NGN";
    status: "ACTIVE";
    replayed: boolean;
  }> {
    const requestHash = hash({
      customerId: input.customerId,
      productVersionId: input.productVersionId,
      currency: input.currency,
      acceptedAt: input.acceptedAt,
      acceptanceReference: input.acceptanceReference,
    });
    const existing = await withTenantTransaction(
      this.database,
      input.tenantId,
      (trx) =>
        trx("savings_accounts")
          .where({
            tenant_id: input.tenantId,
            opening_idempotency_key: input.idempotencyKey,
          })
          .first<{
            id: string;
            product_version_id: string;
            account_number: string;
            currency: string;
            status: string;
            opening_request_hash: string;
          }>(),
    );
    if (existing) {
      if (existing.opening_request_hash !== requestHash)
        throw new Error("Account-opening idempotency conflict");
      return {
        id: existing.id,
        productVersionId: existing.product_version_id,
        accountNumber: existing.account_number,
        currency: "NGN",
        status: "ACTIVE",
        replayed: true,
      };
    }
    const version = await withTenantTransaction(
      this.database,
      input.tenantId,
      (trx) =>
        trx("savings_product_versions as v")
          .join("savings_products as p", function joinProduct() {
            this.on("p.tenant_id", "=", "v.tenant_id").andOn(
              "p.id",
              "=",
              "v.savings_product_id",
            );
          })
          .where({
            "v.tenant_id": input.tenantId,
            "v.id": input.productVersionId,
            "v.status": "PUBLISHED",
            "v.is_current": true,
            "v.currency": input.currency,
          })
          .whereIn("v.product_type", ["ORDINARY", "TARGET"])
          .where("v.effective_from", "<=", trx.fn.now())
          .where((builder) => {
            builder
              .whereNull("v.effective_to")
              .orWhere("v.effective_to", ">", trx.fn.now());
          })
          .first<{
            product_id: string;
            terms_hash: string;
            product_type: "ORDINARY" | "TARGET";
          }>({
            product_id: "v.savings_product_id",
            terms_hash: "v.terms_hash",
            product_type: "v.product_type",
          }),
    );
    if (!version)
      throw new Error("Current published ordinary product version not found");
    const provisioned = await this.ledger.provisionAccount({
      tenantId: input.tenantId,
      customerId: input.customerId,
      purpose:
        version.product_type === "TARGET"
          ? "TARGET_SAVINGS"
          : "ORDINARY_SAVINGS",
      currency: input.currency,
      idempotencyKey: `savings-open:${input.idempotencyKey}:ledger`,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      const replay = await trx("savings_accounts")
        .where({
          tenant_id: input.tenantId,
          opening_idempotency_key: input.idempotencyKey,
        })
        .first<{
          id: string;
          product_version_id: string;
          account_number: string;
          opening_request_hash: string;
        }>();
      if (replay) {
        if (replay.opening_request_hash !== requestHash)
          throw new Error("Account-opening idempotency conflict");
        return {
          id: replay.id,
          productVersionId: replay.product_version_id,
          accountNumber: replay.account_number,
          currency: "NGN" as const,
          status: "ACTIVE" as const,
          replayed: true,
        };
      }
      const sequenceResult = await trx.raw<{ rows: Array<{ value: string }> }>(
        "SELECT nextval(pg_get_serial_sequence('savings_accounts','opening_sequence'))::text AS value",
      );
      const sequence = sequenceResult.rows[0]?.value;
      if (!sequence)
        throw new Error("Could not allocate savings account number");
      const id = randomUUID();
      const accountNumber = `SVG${sequence.padStart(12, "0")}`;
      await trx("savings_accounts").insert({
        id,
        tenant_id: input.tenantId,
        customer_id: input.customerId,
        savings_product_id: version.product_id,
        product_version_id: input.productVersionId,
        product_type: version.product_type,
        account_number: accountNumber,
        currency: input.currency,
        status: "ACTIVE",
        current_balance: "0",
        held_balance: "0",
        ledger_account_id: provisioned.accountId,
        opened_at: trx.fn.now(),
        opening_sequence: sequence,
        opening_idempotency_key: input.idempotencyKey,
        opening_request_hash: requestHash,
        created_by: input.customerId,
      });
      await trx("savings_account_holders").insert({
        tenant_id: input.tenantId,
        savings_account_id: id,
        customer_id: input.customerId,
        role: "PRIMARY",
        mandate_role: "OWNER",
        consent_reference: input.acceptanceReference,
      });
      await trx("savings_account_contracts").insert({
        tenant_id: input.tenantId,
        savings_account_id: id,
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
        savings_account_id: id,
        previous_status: null,
        new_status: "ACTIVE",
        reason_code: "CUSTOMER_OPENED",
        source: "CUSTOMER",
        changed_by: input.customerId,
        request_id: input.idempotencyKey,
        correlation_id: input.correlationId,
      });
      await trx("savings_outbox_events").insert({
        tenant_id: input.tenantId,
        aggregate_type: "savings_account",
        aggregate_id: id,
        aggregate_version: 1,
        event_type: "savings.account-opened.v1",
        event_version: 1,
        correlation_id: input.correlationId,
        request_id: input.idempotencyKey,
        partition_key: `${input.tenantId}:${input.customerId}`,
        payload: {
          savings_account_id: id,
          customer_id: input.customerId,
          product_version_id: input.productVersionId,
          currency: input.currency,
        },
      });
      return {
        id,
        productVersionId: input.productVersionId,
        accountNumber,
        currency: input.currency,
        status: "ACTIVE",
        replayed: false,
      };
    });
  }

  public async contribute(input: {
    tenantId: string;
    customerId: string;
    accountId: string;
    goalId?: string;
    amountMinor: string;
    currency: "NGN";
    correlationId: string;
    idempotencyKey: string;
  }): Promise<{
    contributionId: string;
    savingsAccountId: string;
    ledgerTransactionId: string;
    amountMinor: string;
    currency: "NGN";
    status: "SUCCESSFUL";
    replayed: boolean;
  }> {
    const requestHash = hash({
      customerId: input.customerId,
      accountId: input.accountId,
      goalId: input.goalId ?? null,
      amountMinor: input.amountMinor,
      currency: input.currency,
    });
    const prepared = await withTenantTransaction(
      this.database,
      input.tenantId,
      async (trx) => {
        const existing = await trx("savings_deposits")
          .where({
            tenant_id: input.tenantId,
            idempotency_key: input.idempotencyKey,
          })
          .first<{
            id: string;
            savings_account_id: string;
            amount: string;
            currency: string;
            status: string;
            request_hash: string;
            ledger_transaction_id: string | null;
          }>();
        if (existing) {
          if (existing.request_hash !== requestHash)
            throw new Error("Contribution idempotency conflict");
          return { deposit: existing, account: null };
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
          })
          .whereIn("v.product_type", ["ORDINARY", "TARGET"])
          .forUpdate()
          .first<{
            ledger_account_id: string;
            minimum_deposit: string;
            product_type: "ORDINARY" | "TARGET";
          }>("a.ledger_account_id", "v.minimum_deposit", "v.product_type");
        if (!account) throw new Error("Active savings account not found");
        if ((account.product_type === "TARGET") !== Boolean(input.goalId))
          throw new Error("Target contributions require a matching goal_id");
        if (input.goalId) {
          const goal = await trx("savings_goals")
            .where({
              tenant_id: input.tenantId,
              id: input.goalId,
              savings_account_id: input.accountId,
              customer_id: input.customerId,
              status: "ACTIVE",
            })
            .first<{ id: string }>();
          if (!goal) throw new Error("Active target savings goal not found");
        }
        if (BigInt(input.amountMinor) < BigInt(account.minimum_deposit))
          throw new Error("Contribution is below the product minimum");
        const id = randomUUID();
        await trx("savings_deposits").insert({
          id,
          tenant_id: input.tenantId,
          savings_account_id: input.accountId,
          customer_id: input.customerId,
          deposit_reference: `SVC-${id}`,
          amount: input.amountMinor,
          currency: input.currency,
          channel: "INTERNAL_TRANSFER",
          status: "PENDING",
          operation_id: randomUUID(),
          idempotency_key: input.idempotencyKey,
          correlation_id: input.correlationId,
          request_hash: requestHash,
        });
        return {
          deposit: {
            id,
            savings_account_id: input.accountId,
            amount: input.amountMinor,
            currency: input.currency,
            status: "PENDING",
            request_hash: requestHash,
            ledger_transaction_id: null,
          },
          account,
        };
      },
    );
    if (
      prepared.deposit.status === "SUCCESSFUL" &&
      prepared.deposit.ledger_transaction_id
    )
      return {
        contributionId: prepared.deposit.id,
        savingsAccountId: prepared.deposit.savings_account_id,
        ledgerTransactionId: prepared.deposit.ledger_transaction_id,
        amountMinor: prepared.deposit.amount,
        currency: "NGN",
        status: "SUCCESSFUL",
        replayed: true,
      };
    const account =
      prepared.account ??
      (await withTenantTransaction(this.database, input.tenantId, (trx) =>
        trx("savings_accounts")
          .where({ tenant_id: input.tenantId, id: input.accountId })
          .first<{ ledger_account_id: string }>(),
      ));
    if (!account) throw new Error("Active ordinary savings account not found");
    const wallet = await this.ledger.provisionAccount({
      tenantId: input.tenantId,
      customerId: input.customerId,
      purpose: "WALLET",
      currency: input.currency,
      idempotencyKey: `savings-contribution:${input.idempotencyKey}:wallet`,
    });
    const ledgerRequestHash = hash({
      walletAccountId: wallet.accountId,
      savingsAccountId: account.ledger_account_id,
      amountMinor: input.amountMinor,
      currency: input.currency,
    });
    const posting = await this.ledger.postContribution({
      tenantId: input.tenantId,
      walletAccountId: wallet.accountId,
      savingsAccountId: account.ledger_account_id,
      amountMinor: input.amountMinor,
      currency: input.currency,
      reference: `SVC-${prepared.deposit.id}`,
      idempotencyKey: `savings-contribution:${input.idempotencyKey}:posting`,
    });
    const balance = await this.ledger.getBalance({
      tenantId: input.tenantId,
      accountId: account.ledger_account_id,
    });
    return withTenantTransaction(this.database, input.tenantId, async (trx) => {
      const changed = await trx("savings_deposits")
        .where({
          tenant_id: input.tenantId,
          id: prepared.deposit.id,
          status: "PENDING",
        })
        .update({
          status: "SUCCESSFUL",
          ledger_transaction_id: posting.transactionId,
          ledger_journal_id: posting.journalId,
          ledger_request_hash: ledgerRequestHash,
          ledger_posted_at: trx.fn.now(),
          received_at: trx.fn.now(),
          processed_at: trx.fn.now(),
        });
      if (changed === 1) {
        await trx("savings_accounts")
          .where({ tenant_id: input.tenantId, id: input.accountId })
          .update({
            current_balance: balance.postedBalanceMinor,
            held_balance: balance.heldBalanceMinor,
            total_deposited: trx.raw("total_deposited + ?::bigint", [
              input.amountMinor,
            ]),
            last_ledger_sequence: balance.version,
            ledger_synced_at: trx.fn.now(),
          });
        await trx("savings_outbox_events").insert({
          tenant_id: input.tenantId,
          aggregate_type: "savings_contribution",
          aggregate_id: prepared.deposit.id,
          aggregate_version: 1,
          event_type: "savings.contribution-recorded.v1",
          event_version: 1,
          correlation_id: input.correlationId,
          request_id: input.idempotencyKey,
          partition_key: `${input.tenantId}:${input.accountId}`,
          payload: {
            contribution_id: prepared.deposit.id,
            savings_account_id: input.accountId,
            ledger_transaction_id: posting.transactionId,
            amount_minor: input.amountMinor,
            currency: input.currency,
          },
        });
        if (input.goalId) {
          await trx("savings_goal_contributions").insert({
            tenant_id: input.tenantId,
            goal_id: input.goalId,
            customer_id: input.customerId,
            amount: input.amountMinor,
            currency: input.currency,
            status: "SUCCESSFUL",
            channel: "INTERNAL_TRANSFER",
            ledger_transaction_id: posting.transactionId,
            processed_at: trx.fn.now(),
            deposit_id: prepared.deposit.id,
            contribution_reference: `SVC-${prepared.deposit.id}`,
          });
          await trx("savings_goals")
            .where({ tenant_id: input.tenantId, id: input.goalId })
            .update({
              current_amount: trx.raw("current_amount + ?::bigint", [
                input.amountMinor,
              ]),
            });
        }
      }
      return {
        contributionId: prepared.deposit.id,
        savingsAccountId: input.accountId,
        ledgerTransactionId: posting.transactionId,
        amountMinor: input.amountMinor,
        currency: input.currency,
        status: "SUCCESSFUL",
        replayed: changed !== 1 || posting.replayed,
      };
    });
  }
}

function hash(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}
