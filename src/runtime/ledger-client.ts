import type { ParcTokenClient } from "../security/parc-service-auth.js";
import type { SavingsLedgerGateway } from "../services/ledger-gateway.js";

/**
 * Ledger calls carry an Auth-issued token: delegated while serving a user's
 * request, service-only for background work (see parc-service-auth).
 */
export class LedgerClient implements SavingsLedgerGateway {
  public constructor(
    private readonly baseUrl: string,
    private readonly tokens: Pick<ParcTokenClient, "authorization">,
    private readonly timeoutMs = 5_000,
  ) {}

  public async provisionAccount(
    input: Parameters<SavingsLedgerGateway["provisionAccount"]>[0],
  ): ReturnType<SavingsLedgerGateway["provisionAccount"]> {
    const body = await this.request("/internal/v1/accounts", {
      method: "POST",
      tenantId: input.tenantId,
      idempotencyKey: input.idempotencyKey,
      body: {
        owner_type: input.ownerType ?? "CUSTOMER",
        owner_id: input.customerId,
        purpose: input.purpose,
        account_type: input.accountType ?? "LIABILITY",
        currency: input.currency,
      },
    });
    return {
      accountId: string(body, "account_id"),
      replayed: body.replayed === true,
    };
  }

  public async postContribution(
    input: Parameters<SavingsLedgerGateway["postContribution"]>[0],
  ): ReturnType<SavingsLedgerGateway["postContribution"]> {
    const body = await this.request("/internal/v1/postings", {
      method: "POST",
      tenantId: input.tenantId,
      idempotencyKey: input.idempotencyKey,
      body: {
        reference: input.reference,
        currency: input.currency,
        entries: [
          {
            account_id: input.walletAccountId,
            direction: "DEBIT",
            amount_minor: input.amountMinor,
          },
          {
            account_id: input.savingsAccountId,
            direction: "CREDIT",
            amount_minor: input.amountMinor,
          },
        ],
      },
    });
    return {
      transactionId: string(body, "transaction_id"),
      journalId: string(body, "journal_id"),
      replayed: body.replayed === true,
    };
  }

  public async getBalance(
    input: Parameters<SavingsLedgerGateway["getBalance"]>[0],
  ): ReturnType<SavingsLedgerGateway["getBalance"]> {
    const body = await this.request(
      `/internal/v1/accounts/${input.accountId}/balance`,
      {
        method: "GET",
        tenantId: input.tenantId,
      },
    );
    return {
      postedBalanceMinor: string(body, "posted_balance_minor"),
      heldBalanceMinor: string(body, "held_balance_minor"),
      availableBalanceMinor: string(body, "available_balance_minor"),
      version: number(body, "version"),
    };
  }

  public async postWithdrawal(
    input: Parameters<SavingsLedgerGateway["postWithdrawal"]>[0],
  ): ReturnType<SavingsLedgerGateway["postWithdrawal"]> {
    const body = await this.request("/internal/v1/postings", {
      method: "POST",
      tenantId: input.tenantId,
      idempotencyKey: input.idempotencyKey,
      body: {
        reference: input.reference,
        currency: input.currency,
        entries: [
          {
            account_id: input.savingsAccountId,
            direction: "DEBIT",
            amount_minor: input.amountMinor,
          },
          {
            account_id: input.walletAccountId,
            direction: "CREDIT",
            amount_minor: input.amountMinor,
          },
        ],
      },
    });
    return {
      transactionId: string(body, "transaction_id"),
      journalId: string(body, "journal_id"),
      replayed: body.replayed === true,
    };
  }

  public async postFixedDepositSettlement(
    input: Parameters<SavingsLedgerGateway["postFixedDepositSettlement"]>[0],
  ): ReturnType<SavingsLedgerGateway["postFixedDepositSettlement"]> {
    const principal = BigInt(input.principalMinor);
    const interest = BigInt(input.interestMinor);
    const penalty = BigInt(input.penaltyMinor);
    const payout = principal + interest - penalty;
    if (payout < 0n) throw new Error("Fixed-deposit payout cannot be negative");
    const entries: Array<Record<string, string>> = [
      {
        account_id: input.fixedDepositAccountId,
        direction: "DEBIT",
        amount_minor: principal.toString(),
      },
      {
        account_id: input.walletAccountId,
        direction: "CREDIT",
        amount_minor: payout.toString(),
      },
    ];
    if (interest > 0n)
      entries.push({
        account_id: input.interestExpenseAccountId,
        direction: "DEBIT",
        amount_minor: interest.toString(),
      });
    if (penalty > 0n)
      entries.push({
        account_id: input.penaltyIncomeAccountId,
        direction: "CREDIT",
        amount_minor: penalty.toString(),
      });
    const body = await this.request("/internal/v1/postings", {
      method: "POST",
      tenantId: input.tenantId,
      idempotencyKey: input.idempotencyKey,
      body: { reference: input.reference, currency: input.currency, entries },
    });
    return {
      transactionId: string(body, "transaction_id"),
      journalId: string(body, "journal_id"),
      replayed: body.replayed === true,
    };
  }

  public async postInterestPayment(
    input: Parameters<
      NonNullable<SavingsLedgerGateway["postInterestPayment"]>
    >[0],
  ): ReturnType<NonNullable<SavingsLedgerGateway["postInterestPayment"]>> {
    const body = await this.request("/internal/v1/postings", {
      method: "POST",
      tenantId: input.tenantId,
      idempotencyKey: input.idempotencyKey,
      body: {
        reference: input.reference,
        currency: input.currency,
        entries: [
          {
            account_id: input.interestExpenseAccountId,
            direction: "DEBIT",
            amount_minor: input.amountMinor,
          },
          {
            account_id: input.savingsAccountId,
            direction: "CREDIT",
            amount_minor: input.amountMinor,
          },
        ],
      },
    });
    return {
      transactionId: string(body, "transaction_id"),
      journalId: string(body, "journal_id"),
      replayed: body.replayed === true,
    };
  }

  private async request(
    path: string,
    input: {
      method: "GET" | "POST";
      tenantId: string;
      idempotencyKey?: string;
      body?: object;
    },
  ): Promise<Record<string, unknown>> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      method: input.method,
      headers: {
        ...(input.body ? { "content-type": "application/json" } : {}),
        authorization: await this.tokens.authorization({
          audience: "parc-ledger",
          scopes: [ledgerScope(input.method, path)],
          tenantId: input.tenantId,
        }),
        "x-calling-service": "parc-savings",
        "x-tenant-id": input.tenantId,
        ...(input.idempotencyKey
          ? { "idempotency-key": input.idempotencyKey }
          : {}),
      },
      ...(input.body ? { body: JSON.stringify(input.body) } : {}),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    const body = (await response.json()) as Record<string, unknown>;
    if (!response.ok)
      throw new Error(`Ledger request failed (${response.status})`);
    return body;
  }
}

function ledgerScope(method: "GET" | "POST", path: string): string {
  if (method === "GET") return "ledger.balances.read";
  if (path === "/internal/v1/accounts") return "ledger.accounts.provision";
  return "ledger.postings.write";
}

function string(value: Record<string, unknown>, key: string): string {
  if (typeof value[key] !== "string")
    throw new Error(`Ledger response lacks ${key}`);
  return value[key];
}
function number(value: Record<string, unknown>, key: string): number {
  if (typeof value[key] !== "number")
    throw new Error(`Ledger response lacks ${key}`);
  return value[key];
}
