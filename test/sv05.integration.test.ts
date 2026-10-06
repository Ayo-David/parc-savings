import { randomUUID } from "node:crypto";
import { jest } from "@jest/globals";
import request from "supertest";
import { createApp } from "../src/app.js";
import { testAccess } from "./support/test-access.js";
import { createDatabase } from "../src/database/client.js";
import { OrdinarySavingsService } from "../src/services/ordinary-savings-service.js";
import { RecurringContributionService } from "../src/services/recurring-contribution-service.js";
import { SavingsProductService } from "../src/services/savings-product-service.js";

const connection = process.env.TEST_DATABASE_URL;
const describeDatabase = connection ? describe : describe.skip;

describeDatabase("SV-05 recurring wallet contributions", () => {
  const database = createDatabase(connection ?? "");
  const tenantId = randomUUID();
  const customerId = randomUUID();
  const adminId = randomUUID();
  const checkerId = randomUUID();
  const ledger = {
    provisionAccount: jest.fn(() =>
      Promise.resolve({ accountId: randomUUID(), replayed: false }),
    ),
    postContribution: jest.fn(() =>
      Promise.resolve({
        transactionId: randomUUID(),
        journalId: randomUUID(),
        replayed: false,
      }),
    ),
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
        postedBalanceMinor: "25000",
        heldBalanceMinor: "0",
        availableBalanceMinor: "25000",
        version: 1,
      }),
    ),
  };
  const products = new SavingsProductService(database, {
    consume: (input) =>
      Promise.resolve({
        approvalId: input.approvalId,
        makerId: adminId,
        checkerIds: [checkerId],
        authorityLevel: 1,
        replayed: false,
      }),
  });
  const ordinary = new OrdinarySavingsService(database, ledger);
  let now = new Date("2026-09-13T12:00:00.000Z");
  const recurring = new RecurringContributionService(
    database,
    ledger,
    ordinary,
    () => now,
  );
  const app = createApp(
    products,
    testAccess({ tenantId, customerId: customerId, adminId: adminId }),
    ordinary,
    undefined,
    undefined,
    recurring,
  );
  let accountId: string;

  beforeAll(async () => {
    const product = await products.createProduct({
      tenantId,
      code: `ORD_${randomUUID().slice(0, 8).toUpperCase()}`,
      name: "Recurring destination",
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
        annualRate: "1.0000000000",
        currency: "NGN",
        minimumDepositMinor: "100",
        calculationMethod: "DAILY_BALANCE",
        paymentFrequency: "MONTHLY",
        dayCountBasis: "ACT_365_FIXED",
        compoundingMethod: "SIMPLE",
      },
    });
    await products.publish({
      tenantId,
      productId: product.id,
      versionId: version.id,
      approvalId: randomUUID(),
      publisherId: checkerId,
      correlationId: randomUUID(),
      idempotencyKey: randomUUID(),
    });
    const account = await ordinary.openAccount({
      tenantId,
      customerId,
      productVersionId: version.id,
      currency: "NGN",
      acceptedAt: new Date().toISOString(),
      acceptanceReference: randomUUID(),
      correlationId: randomUUID(),
      idempotencyKey: randomUUID(),
    });
    accountId = account.id;
  });
  afterAll(async () => database.destroy());

  it("creates exactly one wallet-funded plan under idempotent replay", async () => {
    const key = randomUUID();
    const body = {
      savings_account_id: accountId,
      amount_minor: "25000",
      currency: "NGN",
      frequency: "MONTHLY",
      start_date: "2026-09-13",
      max_executions: 2,
      consent_reference: `CONSENT-${randomUUID()}`,
      correlation_id: randomUUID(),
      source: "WALLET",
    };
    const first = await request(app)
      .post("/v1/recurring-plans")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", key)
      .send(body);
    expect(first.status).toBe(201);
    const replay = await request(app)
      .post("/v1/recurring-plans")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", key)
      .send(body);
    expect(replay.status).toBe(200);
    const firstBody = first.body as { recurring_plan_id: string };
    expect(replay.body).toMatchObject({
      recurring_plan_id: firstBody.recurring_plan_id,
      replayed: true,
    });
  });

  it("prevents concurrent duplicate execution and advances the schedule once", async () => {
    now = new Date("2026-09-13T12:00:00.000Z");
    const created = await request(app)
      .post("/v1/recurring-plans")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({
        savings_account_id: accountId,
        amount_minor: "25000",
        currency: "NGN",
        frequency: "MONTHLY",
        start_date: "2026-09-13",
        max_executions: 2,
        consent_reference: `CONSENT-${randomUUID()}`,
        correlation_id: randomUUID(),
        source: "WALLET",
      });
    expect(created.status).toBe(201);
    const planId = (created.body as { recurring_plan_id: string })
      .recurring_plan_id;
    const key = randomUUID();
    const correlation = randomUUID();
    const execute = () =>
      request(app)
        .post(`/internal/v1/recurring-plans/${planId}/execute`)
        .set("authorization", "Bearer test")
        .set("x-tenant-id", tenantId)
        .set("idempotency-key", key)
        .send({
          scheduled_date: "2026-09-13",
          correlation_id: correlation,
          worker_id: randomUUID(),
        });
    const outcomes = await Promise.all([execute(), execute()]);
    if (!outcomes.some((value) => value.status === 201))
      throw new Error(
        JSON.stringify(outcomes.map((value) => value.body as unknown)),
      );
    expect(outcomes.map((value) => value.status).sort()).toEqual([201, 422]);
    const replay = await execute();
    expect(replay.status).toBe(200);
    expect(replay.body).toMatchObject({ status: "SUCCESSFUL", replayed: true });
    const plan = await database("savings_recurring_plans")
      .where({ id: planId })
      .first<Record<string, unknown>>();
    expect(plan).toMatchObject({ execution_count: 1, status: "ACTIVE" });
    expect(plan?.next_execution_date).toBe("2026-10-13");
    const executions = await database("savings_recurring_executions").where({
      recurring_plan_id: planId,
    });
    expect(executions).toHaveLength(1);
  });

  it("bounds retries and advances after an exhausted occurrence", async () => {
    now = new Date("2026-09-13T12:00:00.000Z");
    const created = await request(app)
      .post("/v1/recurring-plans")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({
        savings_account_id: accountId,
        amount_minor: "25000",
        currency: "NGN",
        frequency: "DAILY",
        start_date: "2026-09-13",
        consent_reference: `CONSENT-${randomUUID()}`,
        correlation_id: randomUUID(),
        source: "WALLET",
      });
    const planId = (created.body as { recurring_plan_id: string })
      .recurring_plan_id;
    ledger.postContribution.mockRejectedValueOnce(
      new Error("insufficient funds"),
    );
    ledger.postContribution.mockRejectedValueOnce(
      new Error("insufficient funds"),
    );
    ledger.postContribution.mockRejectedValueOnce(
      new Error("insufficient funds"),
    );
    const key = randomUUID();
    const correlation = randomUUID();
    const execute = () =>
      request(app)
        .post(`/internal/v1/recurring-plans/${planId}/execute`)
        .set("authorization", "Bearer test")
        .set("x-tenant-id", tenantId)
        .set("idempotency-key", key)
        .send({
          scheduled_date: "2026-09-13",
          correlation_id: correlation,
          worker_id: randomUUID(),
        });
    for (let attempt = 0; attempt < 3; attempt += 1) {
      const result = await execute();
      expect(result.status).toBe(201);
      expect(result.body).toMatchObject({ status: "FAILED" });
      now = new Date(now.getTime() + 5 * 60_000);
    }
    const plan = await database("savings_recurring_plans")
      .where({ id: planId })
      .first<Record<string, unknown>>();
    expect(plan).toMatchObject({ execution_count: 1, status: "ACTIVE" });
    expect(plan?.next_execution_date).toBe("2026-09-14");
  });
});
