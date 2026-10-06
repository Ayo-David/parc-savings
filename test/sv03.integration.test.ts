import { randomUUID } from "node:crypto";
import { jest } from "@jest/globals";
import request from "supertest";
import { createApp } from "../src/app.js";
import { testAccess } from "./support/test-access.js";
import { createDatabase } from "../src/database/client.js";
import { OrdinarySavingsService } from "../src/services/ordinary-savings-service.js";
import { SavingsProductService } from "../src/services/savings-product-service.js";
import { TargetSavingsService } from "../src/services/target-savings-service.js";

const connection = process.env.TEST_DATABASE_URL;
const describeDatabase = connection ? describe : describe.skip;

describeDatabase("SV-03 target savings", () => {
  const database = createDatabase(connection ?? "");
  const tenantId = randomUUID();
  const adminId = randomUUID();
  const checkerId = randomUUID();
  const customerId = randomUUID();
  const targetLedgerAccountId = randomUUID();
  const walletLedgerAccountId = randomUUID();
  let ledgerBalance = 0n;
  const ledger = {
    provisionAccount: jest.fn((input: { purpose: string }) =>
      Promise.resolve({
        accountId:
          input.purpose === "WALLET"
            ? walletLedgerAccountId
            : targetLedgerAccountId,
        replayed: false,
      }),
    ),
    postContribution: jest.fn((input: { amountMinor: string }) => {
      ledgerBalance += BigInt(input.amountMinor);
      return Promise.resolve({
        transactionId: randomUUID(),
        journalId: randomUUID(),
        replayed: false,
      });
    }),
    postWithdrawal: jest.fn((input: { amountMinor: string }) => {
      ledgerBalance -= BigInt(input.amountMinor);
      return Promise.resolve({
        transactionId: randomUUID(),
        journalId: randomUUID(),
        replayed: false,
      });
    }),
    postFixedDepositSettlement: jest.fn(() =>
      Promise.resolve({
        transactionId: randomUUID(),
        journalId: randomUUID(),
        replayed: false,
      }),
    ),
    getBalance: jest.fn(() =>
      Promise.resolve({
        postedBalanceMinor: ledgerBalance.toString(),
        heldBalanceMinor: "0",
        availableBalanceMinor: ledgerBalance.toString(),
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
  const accounts = new OrdinarySavingsService(database, ledger);
  const targets = new TargetSavingsService(database, ledger);
  const app = createApp(
    products,
    testAccess({ tenantId, customerId: customerId, adminId: adminId }),
    accounts,
    targets,
  );
  let accountId: string;
  let goalId: string;

  beforeAll(async () => {
    const product = await products.createProduct({
      tenantId,
      code: `TGT_${randomUUID().slice(0, 8).toUpperCase()}`,
      name: "Target savings",
      productType: "TARGET",
      idempotencyKey: randomUUID(),
    });
    const version = await products.createVersion({
      tenantId,
      productId: product.id,
      effectiveFrom: new Date(Date.now() - 1_000).toISOString(),
      createdBy: adminId,
      idempotencyKey: randomUUID(),
      terms: {
        productType: "TARGET",
        annualRate: "12.0000000000",
        currency: "NGN",
        minimumDepositMinor: "1000",
        calculationMethod: "DAILY_BALANCE",
        paymentFrequency: "MONTHLY",
        dayCountBasis: "ACT_365_FIXED",
        compoundingMethod: "SIMPLE",
        earlyWithdrawalAllowed: true,
        partialWithdrawalLimitPercent: "50",
        partialWithdrawalCount: 1,
        withdrawnInterestForfeiture: true,
        breakForfeitsAllInterest: true,
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
    const account = await accounts.openAccount({
      tenantId,
      customerId,
      productVersionId: version.id,
      currency: "NGN",
      acceptedAt: new Date().toISOString(),
      acceptanceReference: `CONSENT-${randomUUID()}`,
      correlationId: randomUUID(),
      idempotencyKey: randomUUID(),
    });
    accountId = account.id;
  });

  afterAll(async () => database.destroy());

  it("creates and funds a target goal using contract-shaped commands", async () => {
    const create = await request(app)
      .post("/v1/savings-goals")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({
        customer_id: customerId,
        savings_account_id: accountId,
        name: "School fees",
        target_amount_minor: "50000",
        currency: "NGN",
        target_date: "2099-12-31",
        correlation_id: randomUUID(),
      });
    expect(create.status).toBe(201);
    const body = create.body as { id: string };
    goalId = body.id;
    expect(create.body as unknown).toMatchObject({
      savings_account_id: accountId,
      customer_id: customerId,
      target_amount_minor: "50000",
      currency: "NGN",
      status: "ACTIVE",
      replayed: false,
    });
    const contribution = await request(app)
      .post(`/v1/savings-accounts/${accountId}/contributions`)
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({
        goal_id: goalId,
        amount_minor: "10000",
        currency: "NGN",
        correlation_id: randomUUID(),
      });
    expect(contribution.status).toBe(201);
    const goal = await database("savings_goals")
      .where({ id: goalId })
      .first<{ current_amount: string }>();
    expect(goal?.current_amount).toBe("10000");
  });

  it("allows one 50 percent withdrawal and forfeits attributable interest", async () => {
    await database("savings_goals")
      .where({ id: goalId })
      .update({ accrued_interest: "1.000000000000" });
    const partial = await request(app)
      .post(`/v1/savings-goals/${goalId}/partial-withdrawal`)
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({
        amount_minor: "5000",
        currency: "NGN",
        correlation_id: randomUUID(),
      });
    expect(partial.status).toBe(201);
    expect(partial.body as unknown).toMatchObject({
      goal_id: goalId,
      principal_minor: "5000",
      forfeited_interest_minor: "50",
      currency: "NGN",
      goal_status: "ACTIVE",
      status: "SUCCESSFUL",
    });
    const second = await request(app)
      .post(`/v1/savings-goals/${goalId}/partial-withdrawal`)
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({
        amount_minor: "1",
        currency: "NGN",
        correlation_id: randomUUID(),
      });
    expect(second.status).toBe(422);
  });

  it("breaks the plan, returns remaining principal, and forfeits all interest", async () => {
    const broken = await request(app)
      .post(`/v1/savings-goals/${goalId}/break`)
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({ currency: "NGN", correlation_id: randomUUID() });
    expect(broken.status).toBe(201);
    expect(broken.body as unknown).toMatchObject({
      goal_id: goalId,
      principal_minor: "5000",
      forfeited_interest_minor: "50",
      goal_status: "CANCELLED",
      status: "SUCCESSFUL",
    });
    const goal = await database("savings_goals").where({ id: goalId }).first<{
      status: string;
      current_amount: string;
      accrued_interest: string;
    }>();
    expect(goal).toMatchObject({
      status: "CANCELLED",
      current_amount: "0",
      accrued_interest: "0.000000000000",
    });
    const events = await database("savings_outbox_events")
      .whereIn("event_type", [
        "savings.goal-created.v1",
        "savings.goal-partially-withdrawn.v1",
        "savings.goal-broken.v1",
      ])
      .andWhere({ tenant_id: tenantId });
    expect(events).toHaveLength(3);
  });
});
