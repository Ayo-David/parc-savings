import { randomUUID } from "node:crypto";
import { jest } from "@jest/globals";
import request from "supertest";
import { createApp } from "../src/app.js";
import { testAccess } from "./support/test-access.js";
import { createDatabase } from "../src/database/client.js";
import { OrdinarySavingsService } from "../src/services/ordinary-savings-service.js";
import { SavingsProductService } from "../src/services/savings-product-service.js";

const connection = process.env.TEST_DATABASE_URL;
const describeDatabase = connection ? describe : describe.skip;

describeDatabase("SV-02 ordinary savings", () => {
  const database = createDatabase(connection ?? "");
  const tenantId = randomUUID();
  const adminId = randomUUID();
  const checkerId = randomUUID();
  const customerId = randomUUID();
  const ledgerSavingsId = randomUUID();
  const ledgerWalletId = randomUUID();
  const ledgerTransactionId = randomUUID();
  const ledgerJournalId = randomUUID();
  const approvals = {
    consume: () =>
      Promise.resolve({
        approvalId: randomUUID(),
        makerId: adminId,
        checkerIds: [checkerId],
        authorityLevel: 1,
        replayed: false,
      }),
  };
  let postedBalance = 0n;
  const ledger = {
    provisionAccount: jest.fn((input: { purpose: string }) =>
      Promise.resolve({
        accountId:
          input.purpose === "WALLET" ? ledgerWalletId : ledgerSavingsId,
        replayed: false,
      }),
    ),
    postContribution: jest.fn((input: { amountMinor: string }) => {
      postedBalance += BigInt(input.amountMinor);
      return Promise.resolve({
        transactionId: ledgerTransactionId,
        journalId: ledgerJournalId,
        replayed: false,
      });
    }),
    postWithdrawal: jest.fn(() =>
      Promise.resolve({
        transactionId: randomUUID(),
        journalId: randomUUID(),
        replayed: false,
      }),
    ),
    postFixedDepositSettlement: jest.fn(() =>
      Promise.resolve({
        transactionId: randomUUID(),
        journalId: randomUUID(),
        replayed: false,
      }),
    ),
    getBalance: jest.fn(() =>
      Promise.resolve({
        postedBalanceMinor: postedBalance.toString(),
        heldBalanceMinor: "0",
        availableBalanceMinor: postedBalance.toString(),
        version: 1,
      }),
    ),
  };
  const products = new SavingsProductService(database, approvals);
  const ordinary = new OrdinarySavingsService(database, ledger);
  const app = createApp(
    products,
    testAccess({ tenantId, customerId: customerId, adminId: adminId }),
    ordinary,
  );
  let productVersionId: string;

  beforeAll(async () => {
    const product = await products.createProduct({
      tenantId,
      code: `ORD_${randomUUID().slice(0, 8).toUpperCase()}`,
      name: "Everyday savings",
      productType: "ORDINARY",
      idempotencyKey: randomUUID(),
    });
    const version = await products.createVersion({
      tenantId,
      productId: product.id,
      effectiveFrom: new Date(Date.now() - 1_000).toISOString(),
      createdBy: adminId,
      idempotencyKey: randomUUID(),
      terms: {
        productType: "ORDINARY",
        annualRate: "5.0000000000",
        currency: "NGN",
        minimumDepositMinor: "1000",
        calculationMethod: "DAILY_BALANCE",
        paymentFrequency: "MONTHLY",
        dayCountBasis: "ACT_365_FIXED",
        compoundingMethod: "SIMPLE",
      },
    });
    productVersionId = version.id;
    await products.publish({
      tenantId,
      productId: product.id,
      versionId: version.id,
      approvalId: randomUUID(),
      publisherId: checkerId,
      correlationId: randomUUID(),
      idempotencyKey: randomUUID(),
    });
  });

  afterAll(async () => database.destroy());

  it("stores final account and deposit amounts as bigint", async () => {
    const rows = await database("information_schema.columns")
      .select("table_name", "column_name", "data_type")
      .whereIn("table_name", ["savings_accounts", "savings_deposits"])
      .whereIn("column_name", ["current_balance", "amount"]);
    expect(rows).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          table_name: "savings_accounts",
          column_name: "current_balance",
          data_type: "bigint",
        }),
        expect.objectContaining({
          table_name: "savings_deposits",
          column_name: "amount",
          data_type: "bigint",
        }),
      ]),
    );
  });

  it("opens an ordinary account and exactly replays the contract-shaped command", async () => {
    const key = randomUUID();
    const body = {
      customer_id: customerId,
      product_version_id: productVersionId,
      currency: "NGN",
      accepted_at: new Date().toISOString(),
      acceptance_reference: `CONSENT-${randomUUID()}`,
      correlation_id: randomUUID(),
    };
    const first = await request(app)
      .post("/v1/savings-accounts")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", key)
      .send(body);
    expect(first.status).toBe(201);
    expect(first.body as unknown).toMatchObject({
      customer_id: customerId,
      product_version_id: productVersionId,
      currency: "NGN",
      status: "ACTIVE",
      replayed: false,
    });
    const replay = await request(app)
      .post("/v1/savings-accounts")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", key)
      .send(body);
    expect(replay.status).toBe(200);
    expect(replay.body as unknown).toMatchObject({ replayed: true });
    expect(ledger.provisionAccount).toHaveBeenCalledTimes(1);
  });

  it("posts a wallet contribution synchronously and emits one conforming fact", async () => {
    const account = await database("savings_accounts")
      .where({ tenant_id: tenantId, customer_id: customerId })
      .first<{ id: string }>();
    expect(account).toBeDefined();
    const key = randomUUID();
    const body = {
      amount_minor: "2500",
      currency: "NGN",
      correlation_id: randomUUID(),
    };
    const first = await request(app)
      .post(`/v1/savings-accounts/${String(account?.id)}/contributions`)
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", key)
      .send(body);
    expect(first.status).toBe(201);
    expect(first.body as unknown).toMatchObject({
      savings_account_id: account?.id,
      ledger_transaction_id: ledgerTransactionId,
      amount_minor: "2500",
      currency: "NGN",
      status: "SUCCESSFUL",
      replayed: false,
    });
    const replay = await request(app)
      .post(`/v1/savings-accounts/${String(account?.id)}/contributions`)
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", key)
      .send(body);
    expect(replay.status).toBe(200);
    expect(replay.body as unknown).toMatchObject({ replayed: true });
    expect(ledger.postContribution).toHaveBeenCalledTimes(1);
    const deposit = await database("savings_deposits")
      .where({ tenant_id: tenantId, idempotency_key: key })
      .first<{ status: string; amount: string; ledger_journal_id: string }>();
    expect(deposit).toMatchObject({
      status: "SUCCESSFUL",
      amount: "2500",
      ledger_journal_id: ledgerJournalId,
    });
    const events = await database("savings_outbox_events").where({
      tenant_id: tenantId,
      event_type: "savings.contribution-recorded.v1",
    });
    expect(events).toHaveLength(1);
  });
});
