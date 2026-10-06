import type { Knex } from "knex";
import { withTenantTransaction } from "../database/client.js";
import type { SavingsLedgerGateway } from "./ledger-gateway.js";

interface AccountRow {
  id: string;
  account_number: string;
  product_type: "ORDINARY" | "TARGET" | "FIXED_DEPOSIT" | "RECURRING";
  product_version_id: string;
  ledger_account_id: string;
  currency: "NGN";
  status: string;
}

export class SavingsSummaryService {
  public constructor(
    private readonly database: Knex,
    private readonly ledger: SavingsLedgerGateway,
  ) {}

  public async get(input: { tenantId: string; customerId: string }): Promise<{
    accounts: Array<{
      savings_account_id: string;
      account_number: string;
      product_type: AccountRow["product_type"];
      product_version_id: string;
      currency: "NGN";
      status: string;
      posted_balance_minor: string;
      held_balance_minor: string;
      available_balance_minor: string;
    }>;
    totals: Array<{
      currency: "NGN";
      posted_balance_minor: string;
      held_balance_minor: string;
      available_balance_minor: string;
    }>;
  }> {
    const rows = await withTenantTransaction(
      this.database,
      input.tenantId,
      (transaction) =>
        transaction("savings_accounts")
          .where({
            tenant_id: input.tenantId,
            customer_id: input.customerId,
          })
          .whereNull("closed_at")
          .orderBy("opened_at", "asc")
          .select(
            "id",
            "account_number",
            "product_type",
            "product_version_id",
            "ledger_account_id",
            "currency",
            "status",
          ) as Promise<AccountRow[]>,
    );
    const accounts = await Promise.all(
      rows.map(async (row) => {
        const balance = await this.ledger.getBalance({
          tenantId: input.tenantId,
          accountId: row.ledger_account_id,
        });
        return {
          savings_account_id: row.id,
          account_number: row.account_number,
          product_type: row.product_type,
          product_version_id: row.product_version_id,
          currency: row.currency,
          status: row.status,
          posted_balance_minor: balance.postedBalanceMinor,
          held_balance_minor: balance.heldBalanceMinor,
          available_balance_minor: balance.availableBalanceMinor,
        };
      }),
    );
    const total = accounts.reduce(
      (sum, account) => ({
        posted: sum.posted + BigInt(account.posted_balance_minor),
        held: sum.held + BigInt(account.held_balance_minor),
        available: sum.available + BigInt(account.available_balance_minor),
      }),
      { posted: 0n, held: 0n, available: 0n },
    );
    return {
      accounts,
      totals: [
        {
          currency: "NGN",
          posted_balance_minor: total.posted.toString(),
          held_balance_minor: total.held.toString(),
          available_balance_minor: total.available.toString(),
        },
      ],
    };
  }
}
