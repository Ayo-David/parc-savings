import { randomUUID } from "node:crypto";
import { jest } from "@jest/globals";
import request from "supertest";
import { createApp } from "../src/app.js";
import { testAccess } from "./support/test-access.js";
import { createDatabase } from "../src/database/client.js";
import { FixedDepositService } from "../src/services/fixed-deposit-service.js";
import { SavingsProductService } from "../src/services/savings-product-service.js";

const connection = process.env.TEST_DATABASE_URL;
const describeDatabase = connection ? describe : describe.skip;

describeDatabase("SV-04 fixed deposits", () => {
  const database = createDatabase(connection ?? "");
  const tenantId = randomUUID();
  const adminId = randomUUID();
  const checkerId = randomUUID();
  const customerId = randomUUID();
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
        postedBalanceMinor: "0",
        heldBalanceMinor: "0",
        availableBalanceMinor: "0",
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
  let now = new Date("2026-09-13T12:00:00.000Z");
  const fixed = new FixedDepositService(database, ledger, () => now);
  const app = createApp(
    products,
    testAccess({ tenantId, customerId: customerId, adminId: customerId }),
    undefined,
    undefined,
    fixed,
  );
  let versionId: string;

  beforeAll(async () => {
    const product = await products.createProduct({
      tenantId,
      code: `FD_${randomUUID().slice(0, 8).toUpperCase()}`,
      name: "Fixed deposit",
      productType: "FIXED_DEPOSIT",
      idempotencyKey: randomUUID(),
    });
    const version = await products.createVersion({
      tenantId,
      productId: product.id,
      effectiveFrom: new Date(Date.now() - 1_000).toISOString(),
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
    versionId = version.id;
    await products.publish({
      tenantId,
      productId: product.id,
      versionId,
      approvalId: randomUUID(),
      publisherId: checkerId,
      correlationId: randomUUID(),
      idempotencyKey: randomUUID(),
    });
  });
  afterAll(async () => database.destroy());

  async function place(acceptedAt: string) {
    const quote = await request(app)
      .post("/v1/customer/fixed-deposit-quotes")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({
        product_version_id: versionId,
        principal_minor: "100000",
        currency: "NGN",
        tenor_days: 30,
        correlation_id: randomUUID(),
      });
    if (quote.status !== 200) throw new Error(JSON.stringify(quote.body));
    expect(quote.status).toBe(200);
    return request(app)
      .post("/v1/fixed-deposits")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({
        product_version_id: versionId,
        amount_minor: "100000",
        currency: "NGN",
        tenure_days: 30,
        quote_id: (quote.body as { quote_id: string }).quote_id,
        quote_hash: (quote.body as { quote_hash: string }).quote_hash,
        accepted_at: acceptedAt,
        acceptance_reference: `CONSENT-${randomUUID()}`,
        correlation_id: randomUUID(),
      });
  }

  it("places and liquidates using the immutable penalty", async () => {
    now = new Date("2026-09-13T12:00:00.000Z");
    const placement = await place(new Date().toISOString());
    if (placement.status !== 201)
      throw new Error(JSON.stringify(placement.body));
    expect(placement.status).toBe(201);
    const id = (placement.body as { fixed_deposit_id: string })
      .fixed_deposit_id;
    const detail = await request(app)
      .get(`/v1/customer/fixed-deposits/${id}`)
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId);
    expect(detail.status).toBe(200);
    expect(detail.body as unknown).toMatchObject({
      fixed_deposit_id: id,
      principal_minor: "100000",
      maturity_instruction: "payout",
      status: "ACTIVE",
    });
    const instruction = await request(app)
      .put(`/v1/fixed-deposits/${id}/maturity-instruction`)
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({
        instruction: "payout",
        currency: "NGN",
        correlation_id: randomUUID(),
      });
    expect(instruction.status).toBe(200);
    expect(instruction.body as unknown).toMatchObject({
      instruction: "payout",
      replayed: false,
    });
    await database("fixed_deposits").where({ id }).update({
      interest_amount: "10.555000000000",
      maturity_amount: "101056",
    });
    const quote = await request(app)
      .post(`/v1/fixed-deposits/${id}/liquidation-quote`)
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({ currency: "NGN", correlation_id: randomUUID() });
    expect(quote.status).toBe(200);
    const liquidation = await request(app)
      .post(`/v1/fixed-deposits/${id}/liquidate`)
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", randomUUID())
      .send({
        currency: "NGN",
        correlation_id: randomUUID(),
        quote_id: (quote.body as { quote_id: string }).quote_id,
        quote_hash: (quote.body as { quote_hash: string }).quote_hash,
      });
    expect(liquidation.status).toBe(201);
    expect(liquidation.body as unknown).toMatchObject({
      fixed_deposit_id: id,
      principal_minor: "100000",
      interest_minor: "1056",
      penalty_minor: "2500",
      payout_minor: "98556",
      currency: "NGN",
      status: "LIQUIDATED",
      replayed: false,
    });
  });

  it("matures once under scheduled system authority", async () => {
    now = new Date("2026-09-13T12:00:00.000Z");
    const placement = await place(new Date().toISOString());
    if (placement.status !== 201)
      throw new Error(JSON.stringify(placement.body));
    expect(placement.status).toBe(201);
    const id = (placement.body as { fixed_deposit_id: string })
      .fixed_deposit_id;
    now = new Date("2026-10-14T12:00:00.000Z");
    await database("fixed_deposits").where({ id }).update({
      interest_amount: "12.345000000000",
      maturity_amount: "101234",
    });
    const key = randomUUID();
    const correlation = randomUUID();
    const first = await request(app)
      .post(`/internal/v1/fixed-deposits/${id}/mature`)
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", key)
      .send({ currency: "NGN", correlation_id: correlation });
    if (first.status !== 201) throw new Error(JSON.stringify(first.body));
    expect(first.status).toBe(201);
    expect(first.body as unknown).toMatchObject({
      fixed_deposit_id: id,
      interest_minor: "1234",
      penalty_minor: "0",
      payout_minor: "101234",
      status: "MATURED",
    });
    const replay = await request(app)
      .post(`/internal/v1/fixed-deposits/${id}/mature`)
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", key)
      .send({ currency: "NGN", correlation_id: correlation });
    expect(replay.status).toBe(200);
    expect(replay.body as unknown).toMatchObject({ replayed: true });
    const events = await database("savings_outbox_events").where({
      tenant_id: tenantId,
      aggregate_type: "fixed_deposit",
      aggregate_id: id,
    });
    expect(events).toHaveLength(2);
  });

  it.each([
    ["renew_principal", "100000"],
    ["renew_principal_and_interest", "101234"],
  ])(
    "executes %s and replays the linked renewal",
    async (instruction, expectedPrincipal) => {
      now = new Date("2026-09-13T12:00:00.000Z");
      const placement = await place(new Date().toISOString());
      if (placement.status !== 201)
        throw new Error(JSON.stringify(placement.body));
      expect(placement.status).toBe(201);
      const id = (placement.body as { fixed_deposit_id: string })
        .fixed_deposit_id;
      const instructionResponse = await request(app)
        .put(`/v1/fixed-deposits/${id}/maturity-instruction`)
        .set("authorization", "Bearer test")
        .set("x-tenant-id", tenantId)
        .set("idempotency-key", randomUUID())
        .send({
          instruction,
          renewal_tenure_days: 30,
          currency: "NGN",
          correlation_id: randomUUID(),
        });
      expect(instructionResponse.status).toBe(200);
      await database("fixed_deposits").where({ id }).update({
        interest_amount: "12.345000000000",
        maturity_amount: "101234",
      });
      now = new Date("2026-10-14T12:00:00.000Z");
      const key = randomUUID();
      const correlation = randomUUID();
      const first = await request(app)
        .post(`/internal/v1/fixed-deposits/${id}/mature`)
        .set("authorization", "Bearer test")
        .set("x-tenant-id", tenantId)
        .set("idempotency-key", key)
        .send({ currency: "NGN", correlation_id: correlation });
      if (first.status !== 201) throw new Error(JSON.stringify(first.body));
      expect(first.body as unknown).toMatchObject({
        fixed_deposit_id: id,
        status: "RENEWED",
        renewed_principal_minor: expectedPrincipal,
        replayed: false,
      });
      const renewedId = (first.body as { renewed_fixed_deposit_id: string })
        .renewed_fixed_deposit_id;
      expect(renewedId).toBeDefined();
      const renewed = await database("fixed_deposits")
        .where({ id: renewedId })
        .first<Record<string, unknown>>();
      expect(renewed).toMatchObject({
        previous_fixed_deposit_id: id,
        principal_amount: expectedPrincipal,
        status: "ACTIVE",
      });
      const replay = await request(app)
        .post(`/internal/v1/fixed-deposits/${id}/mature`)
        .set("authorization", "Bearer test")
        .set("x-tenant-id", tenantId)
        .set("idempotency-key", key)
        .send({ currency: "NGN", correlation_id: correlation });
      expect(replay.status).toBe(200);
      expect(replay.body as unknown).toMatchObject({
        renewed_fixed_deposit_id: renewedId,
        replayed: true,
      });
    },
  );
});
