import { randomUUID } from "node:crypto";
import { jest } from "@jest/globals";
import request from "supertest";
import { createApp } from "../src/app.js";
import { testAccess } from "./support/test-access.js";
import { createDatabase } from "../src/database/client.js";
import { SavingsProductService } from "../src/services/savings-product-service.js";

const connection = process.env.TEST_DATABASE_URL;
const describeDatabase = connection ? describe : describe.skip;

describeDatabase("SV-01 savings product catalog", () => {
  const database = createDatabase(connection ?? "");
  const tenantId = randomUUID();
  const makerId = randomUUID();
  const checkerId = randomUUID();
  const approvalId = randomUUID();
  const approvals = {
    consume: jest.fn(() =>
      Promise.resolve({
        approvalId,
        makerId,
        checkerIds: [checkerId],
        authorityLevel: 1,
        replayed: false,
      }),
    ),
  };
  const service = new SavingsProductService(database, approvals);
  const app = createApp(
    service,
    testAccess({ tenantId, customerId: makerId, adminId: makerId }),
  );

  afterAll(async () => database.destroy());

  it("keeps approved monetary and rate storage types", async () => {
    const columns = await database("information_schema.columns")
      .select("column_name", "data_type", "numeric_precision", "numeric_scale")
      .where({ table_schema: "public", table_name: "savings_product_versions" })
      .whereIn("column_name", ["minimum_deposit", "annual_rate"]);
    expect(columns).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          column_name: "minimum_deposit",
          data_type: "bigint",
        }),
        expect.objectContaining({
          column_name: "annual_rate",
          data_type: "numeric",
          numeric_precision: 18,
          numeric_scale: 10,
        }),
      ]),
    );
  });

  it("creates and replays the contract-shaped ordinary product command", async () => {
    const key = randomUUID();
    const body = {
      code: `ORD_${randomUUID().slice(0, 8).toUpperCase()}`,
      name: "Ordinary savings",
      product_type: "ORDINARY",
    };
    const first = await request(app)
      .post("/v1/savings-products")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", key)
      .send(body);
    expect(first.status).toBe(201);
    expect(first.body).toMatchObject({ status: "DRAFT", replayed: false });
    const replay = await request(app)
      .post("/v1/savings-products")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId)
      .set("idempotency-key", key)
      .send(body);
    const firstBody = first.body as { id: string };
    expect(replay.body as unknown).toMatchObject({
      id: firstBody.id,
      replayed: true,
    });
  });

  it("enforces product-specific immutable terms and maker-checker publication", async () => {
    const product = await service.createProduct({
      tenantId,
      code: `TGT_${randomUUID().slice(0, 8).toUpperCase()}`,
      name: "Target savings",
      productType: "TARGET",
      idempotencyKey: randomUUID(),
    });
    await expect(
      service.createVersion({
        tenantId,
        productId: product.id,
        createdBy: makerId,
        effectiveFrom: new Date().toISOString(),
        idempotencyKey: randomUUID(),
        terms: targetTerms({ partialWithdrawalCount: 2 }),
      }),
    ).rejects.toThrow("approved early-withdrawal policy");

    const version = await service.createVersion({
      tenantId,
      productId: product.id,
      createdBy: makerId,
      effectiveFrom: new Date().toISOString(),
      idempotencyKey: randomUUID(),
      terms: targetTerms(),
    });
    const publishKey = randomUUID();
    const correlationId = randomUUID();
    const published = await service.publish({
      tenantId,
      productId: product.id,
      versionId: version.id,
      approvalId,
      publisherId: checkerId,
      idempotencyKey: publishKey,
      correlationId,
    });
    expect(published).toEqual({
      id: version.id,
      status: "PUBLISHED",
      replayed: false,
    });
    expect(
      await service.publish({
        tenantId,
        productId: product.id,
        versionId: version.id,
        approvalId,
        publisherId: checkerId,
        idempotencyKey: publishKey,
        correlationId,
      }),
    ).toMatchObject({ replayed: true });
    await expect(
      database("savings_product_versions")
        .where({ id: version.id })
        .update({ annual_rate: "13.0000000000" }),
    ).rejects.toThrow("immutable");
    const outbox = await database("savings_outbox_events")
      .where({
        aggregate_id: version.id,
        event_type: "savings.product-version-published.v1",
      })
      .first<{ id: string }>();
    expect(outbox).toBeDefined();
  });
});

function targetTerms(overrides: { partialWithdrawalCount?: number } = {}) {
  return {
    productType: "TARGET" as const,
    annualRate: "12.0000000000",
    currency: "NGN" as const,
    minimumDepositMinor: "10000",
    calculationMethod: "DAILY_BALANCE" as const,
    paymentFrequency: "MONTHLY" as const,
    dayCountBasis: "ACT_365_FIXED" as const,
    compoundingMethod: "SIMPLE" as const,
    earlyWithdrawalAllowed: true,
    partialWithdrawalLimitPercent: "50",
    partialWithdrawalCount: overrides.partialWithdrawalCount ?? 1,
    withdrawnInterestForfeiture: true,
    breakForfeitsAllInterest: true,
  };
}
