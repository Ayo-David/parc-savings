import { randomUUID } from "node:crypto";
import { jest } from "@jest/globals";
import {
  createLocalJWKSet,
  exportJWK,
  generateKeyPair,
  SignJWT,
  type JWTPayload,
} from "jose";
import request from "supertest";
import { createApp } from "../src/app.js";
import { createParcAuth } from "../src/security/parc-service-auth.js";
import type { InterestService } from "../src/services/interest-service.js";
import type { SavingsProductService } from "../src/services/savings-product-service.js";
import type { SavingsSummaryService } from "../src/services/savings-summary-service.js";

const issuer = "https://auth.parc.invalid";
const tenantId = "11111111-1111-4111-8111-111111111111";
const customerId = "22222222-2222-4222-8222-222222222222";
const adminId = "33333333-3333-4333-8333-333333333333";
const sessionId = "44444444-4444-4444-8444-444444444444";

describe("Savings authorizes the user and the acting service from one token", () => {
  let sign: (claims: JWTPayload, audience?: string) => Promise<string>;
  let app: ReturnType<typeof createApp>;
  const summary = jest.fn(() => Promise.resolve({ accounts: [], totals: [] }));
  const createProduct = jest.fn(() =>
    Promise.resolve({ id: randomUUID(), replayed: false }),
  );
  const accrue = jest.fn(() =>
    Promise.resolve({
      accrualId: randomUUID(),
      accountId: randomUUID(),
      accrualDate: "2026-10-01",
      interestUnroundedMinor: "1.5",
      currency: "NGN",
      replayed: false,
    }),
  );

  beforeAll(async () => {
    const keys = await generateKeyPair("RS256");
    const jwks = createLocalJWKSet({
      keys: [{ ...(await exportJWK(keys.publicKey)), kid: "k1", alg: "RS256" }],
    });
    sign = (claims, audience = "parc-savings") =>
      new SignJWT(claims)
        .setProtectedHeader({ alg: "RS256", kid: "k1" })
        .setIssuer(issuer)
        .setAudience(audience)
        .setJti(randomUUID())
        .setIssuedAt()
        .setExpirationTime("5m")
        .sign(keys.privateKey);
    app = createApp(
      { createProduct } as unknown as SavingsProductService,
      createParcAuth({ issuer, audience: "parc-savings", keys: jwks }),
      undefined,
      undefined,
      undefined,
      undefined,
      { accrue } as unknown as InterestService,
      { get: summary } as unknown as SavingsSummaryService,
    );
  });

  const customer = (overrides: JWTPayload = {}) =>
    sign({
      sub: customerId,
      client_id: "parc-mobile-bff",
      token_use: "delegated",
      tenant_id: tenantId,
      scope: "savings.customer.read savings.customer.write",
      subject_type: "CUSTOMER",
      subject_scope: "TENANT",
      session_id: sessionId,
      act: { sub: "parc-mobile-bff" },
      ...overrides,
    });
  const admin = (scope: string, overrides: JWTPayload = {}) =>
    sign({
      sub: adminId,
      client_id: "parc-admin-bff",
      token_use: "delegated",
      tenant_id: tenantId,
      scope,
      subject_type: "ADMINISTRATOR",
      subject_scope: "TENANT",
      session_id: sessionId,
      act: { sub: "parc-admin-bff" },
      ...overrides,
    });
  const service = (scope: string, client = "parc-scheduler") =>
    sign({
      sub: client,
      client_id: client,
      token_use: "service",
      tenant_id: tenantId,
      scope,
    });
  const summaryRequest = (token: string, tenant = tenantId) =>
    request(app)
      .get("/v1/customer/savings-summary")
      .set("authorization", `Bearer ${token}`)
      .set("x-tenant-id", tenant);

  it("serves a customer delegated through the Mobile BFF as that customer", async () => {
    await summaryRequest(await customer()).expect(200);
    expect(summary).toHaveBeenCalledWith({ tenantId, customerId });
  });

  it("rejects the wrong user type, acting service, scope, kind, tenant or audience", async () => {
    const cases: Array<[string, number, string?]> = [
      [await admin("savings.customer.read"), 403, "SUBJECT_FORBIDDEN"],
      [
        await customer({
          client_id: "parc-lending",
          act: { sub: "parc-lending" },
        }),
        403,
        "CALLER_FORBIDDEN",
      ],
      [
        await customer({ scope: "savings.customer.write" }),
        403,
        "INSUFFICIENT_SCOPE",
      ],
      [await service("savings.customer.read"), 403, "TOKEN_KIND_FORBIDDEN"],
      [
        await sign(
          {
            sub: customerId,
            tenant_id: tenantId,
            session_id: sessionId,
            subject_type: "CUSTOMER",
          },
          "mobile-bff",
        ),
        401,
      ],
    ];
    for (const [token, status, code] of cases) {
      const response = await summaryRequest(token);
      expect(response.status).toBe(status);
      if (code) expect(response.body).toMatchObject({ code });
    }
    expect((await summaryRequest(await customer(), randomUUID())).status).toBe(
      403,
    );
    expect(summary).toHaveBeenCalledTimes(1);
  });

  it("requires the administrator's product scope via the Admin BFF", async () => {
    const body = { code: "ORD_1", name: "Everyday", product_type: "ORDINARY" };
    const create = (token: string) =>
      request(app)
        .post("/v1/savings-products")
        .set("authorization", `Bearer ${token}`)
        .set("x-tenant-id", tenantId)
        .set("idempotency-key", randomUUID())
        .send(body);
    expect((await create(await admin("savings.products.publish"))).status).toBe(
      403,
    );
    expect(
      (await create(await customer({ scope: "savings.products.manage" })))
        .status,
    ).toBe(403);
    expect((await create(await admin("savings.products.manage"))).status).toBe(
      201,
    );
    expect(createProduct).toHaveBeenCalledWith(
      expect.objectContaining({ tenantId }),
    );
  });

  it("accepts service-only tokens for background interest processing", async () => {
    const accrual = (token: string) =>
      request(app)
        .post("/internal/v1/interest/accruals")
        .set("authorization", `Bearer ${token}`)
        .set("x-tenant-id", tenantId)
        .set("idempotency-key", randomUUID())
        .send({
          savings_account_id: randomUUID(),
          accrual_date: "2026-10-01",
          currency: "NGN",
          correlation_id: randomUUID(),
        });
    expect(
      (await accrual(await service("savings.operations.process"))).status,
    ).toBe(201);
    expect(
      (await accrual(await admin("savings.operations.process"))).status,
    ).toBe(201);
    expect(
      (await accrual(await customer({ scope: "savings.operations.process" })))
        .status,
    ).toBe(403);
    expect(
      (await accrual(await service("savings.customer.write"))).status,
    ).toBe(403);
  });
});
