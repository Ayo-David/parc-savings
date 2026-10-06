import { randomUUID } from "node:crypto";
import { jest } from "@jest/globals";
import request from "supertest";
import { createApp } from "../src/app.js";
import { testAccess } from "./support/test-access.js";
import { createDatabase } from "../src/database/client.js";
import { FixedDepositService } from "../src/services/fixed-deposit-service.js";
import { InterestService } from "../src/services/interest-service.js";
import { OrdinarySavingsService } from "../src/services/ordinary-savings-service.js";
import { SavingsProductService } from "../src/services/savings-product-service.js";

const connection = process.env.TEST_DATABASE_URL;
const describeDatabase = connection ? describe : describe.skip;

describeDatabase("SV-06 interest accrual and payment", () => {
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
    postInterestPayment: jest.fn(() =>
      Promise.resolve({
        transactionId: randomUUID(),
        journalId: randomUUID(),
        replayed: false,
      }),
    ),
    getBalance: jest.fn(() =>
      Promise.resolve({
        postedBalanceMinor: "10001",
        heldBalanceMinor: "0",
        availableBalanceMinor: "10001",
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
  const fixed = new FixedDepositService(
    database,
    ledger,
    () => new Date("2026-09-13T12:00:00.000Z"),
  );
  const interest = new InterestService(
    database,
    ledger,
    () => new Date("2026-09-13T12:00:00.000Z"),
  );
  const app = createApp(
    products,
    testAccess({ tenantId, customerId: customerId, adminId: adminId }),
    ordinary,
    undefined,
    fixed,
    undefined,
    interest,
  );
  let accountId: string;
  let fixedAccountId: string;

  beforeAll(async () => {
    const product = await products.createProduct({
      tenantId,
      code: `INT_${randomUUID().slice(0, 8).toUpperCase()}`,
      name: "Interest savings",
      productType: "ORDINARY",
      idempotencyKey: randomUUID(),
    });
    const version = await products.createVersion({
      tenantId,
      productId: product.id,
      effectiveFrom: "2026-01-01T00:00:00.000Z",
      createdBy: adminId,
      idempotencyKey: randomUUID(),
      terms: {
        productType: "ORDINARY",
        annualRate: "5.0000000000",
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
    await database("savings_accounts")
      .where({ id: accountId })
      .update({ current_balance: "10001", total_deposited: "10001" });

    const fixedProduct = await products.createProduct({
      tenantId,
      code: `INT_FD_${randomUUID().slice(0, 8).toUpperCase()}`,
      name: "Interest fixed deposit",
      productType: "FIXED_DEPOSIT",
      idempotencyKey: randomUUID(),
    });
    const fixedVersion = await products.createVersion({
      tenantId,
      productId: fixedProduct.id,
      effectiveFrom: "2026-01-01T00:00:00.000Z",
      createdBy: adminId,
      idempotencyKey: randomUUID(),
      terms: {
        productType: "FIXED_DEPOSIT",
        annualRate: "12.0000000000",
        currency: "NGN",
        minimumDepositMinor: "10000",
        calculationMethod: "FIXED",
        paymentFrequency: "AT_MATURITY",
        dayCountBasis: "ACT_365_FIXED",
        compoundingMethod: "SIMPLE",
        earlyWithdrawalAllowed: true,
        earlyLiquidationPenaltyRate: "2.5000000000",
        minimumTenureDays: 30,
        maximumTenureDays: 365,
      },
    });
    await products.publish({
      tenantId,
      productId: fixedProduct.id,
      versionId: fixedVersion.id,
      approvalId: randomUUID(),
      publisherId: checkerId,
      correlationId: randomUUID(),
      idempotencyKey: randomUUID(),
    });
    const quote = await fixed.quotePlacement({
      tenantId,
      customerId,
      productVersionId: fixedVersion.id,
      principalMinor: "100000",
      currency: "NGN",
      tenureDays: 30,
      correlationId: randomUUID(),
      idempotencyKey: randomUUID(),
    });
    const deposit = await fixed.create({
      tenantId,
      customerId,
      productVersionId: fixedVersion.id,
      amountMinor: "100000",
      currency: "NGN",
      tenureDays: 30,
      quoteId: quote.quoteId,
      quoteHash: quote.quoteHash,
      acceptedAt: "2026-09-13T12:00:00.000Z",
      acceptanceReference: randomUUID(),
      correlationId: randomUUID(),
      idempotencyKey: randomUUID(),
    });
    const fixedDeposit = await database("fixed_deposits")
      .where({ tenant_id: tenantId, id: deposit.fixedDepositId })
      .first<{ savings_account_id: string }>();
    if (!fixedDeposit) throw new Error("Fixed-deposit fixture was not stored");
    fixedAccountId = fixedDeposit.savings_account_id;
  });
  afterAll(async () => database.destroy());

  it("retains unrounded daily precision and posts one explicit residual", async () => {
    for (const date of ["2026-09-12", "2026-09-13"]) {
      const response = await request(app)
        .post("/internal/v1/interest/accruals")
        .set("authorization", "Bearer test")
        .set("x-tenant-id", tenantId)
        .set("idempotency-key", randomUUID())
        .send({
          savings_account_id: accountId,
          accrual_date: date,
          currency: "NGN",
          correlation_id: randomUUID(),
        });
      if (response.status !== 201)
        throw new Error(JSON.stringify(response.body));
      expect(response.body).toMatchObject({
        interest_unrounded_minor: "1.370000000000",
      });
    }
    const key = randomUUID();
    const body = {
      savings_account_id: accountId,
      period_start: "2026-09-12",
      period_end: "2026-09-13",
      currency: "NGN",
      correlation_id: randomUUID(),
    };
    const paid = await request(app)
      .post("/internal/v1/interest/payments")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", key)
      .send(body);
    if (paid.status !== 201) throw new Error(JSON.stringify(paid.body));
    expect(paid.body).toMatchObject({
      amount_minor: "3",
      rounding_residual_minor: "1",
      status: "SUCCESSFUL",
      replayed: false,
    });
    const replay = await request(app)
      .post("/internal/v1/interest/payments")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", key)
      .send(body);
    expect(replay.status).toBe(200);
    expect(replay.body).toMatchObject({ amount_minor: "3", replayed: true });
    expect(ledger.postInterestPayment).toHaveBeenCalledTimes(1);
    const allocations = await database<Record<string, unknown>>(
      "savings_interest_payment_accruals",
    ).where({ tenant_id: tenantId });
    expect(allocations.map((row) => String(row.allocated_minor))).toEqual([
      "1",
      "1",
    ]);
  });

  it("accrues fixed-deposit interest from immutable principal and rate", async () => {
    const response = await request(app)
      .post("/internal/v1/interest/accruals")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({
        savings_account_id: fixedAccountId,
        accrual_date: "2026-09-13",
        currency: "NGN",
        correlation_id: randomUUID(),
      });
    if (response.status !== 201) throw new Error(JSON.stringify(response.body));
    expect(response.body).toMatchObject({
      interest_unrounded_minor: "32.876712328767",
      replayed: false,
    });
    const deposit = await database("fixed_deposits")
      .where({ tenant_id: tenantId, savings_account_id: fixedAccountId })
      .first<Record<string, unknown>>();
    expect(String(deposit?.interest_amount)).toBe("0.328767123288");
    expect(String(deposit?.maturity_amount)).toBe("100033");
  });
});
