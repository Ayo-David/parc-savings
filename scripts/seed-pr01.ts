import knex from "knex";
import { z } from "zod";
import { LedgerClient } from "../src/runtime/ledger-client.js";
import { ParcTokenClient } from "../src/security/parc-service-auth.js";
import { OrdinarySavingsService } from "../src/services/ordinary-savings-service.js";
import {
  SavingsProductService,
  type ProductType,
  type ProductVersionTerms,
} from "../src/services/savings-product-service.js";

const config = z
  .object({
    NODE_ENV: z.enum(["development", "test"]),
    DATABASE_URL: z.string().url(),
    LEDGER_URL: z.string().url(),
    AUTH_JWT_ISSUER: z.string().url(),
    AUTH_TOKEN_URL: z.string().url(),
    SERVICE_CLIENT_KEY_ID: z.string().min(1),
    SERVICE_CLIENT_PRIVATE_KEY_BASE64: z.string().min(1),
    PR01_TENANT_A_ID: z.string().uuid(),
    PR01_TENANT_B_ID: z.string().uuid(),
    PR01_CUSTOMER_A_ID: z.string().uuid(),
    PR01_CUSTOMER_B_ID: z.string().uuid(),
  })
  .parse(process.env);

const database = knex({ client: "pg", connection: config.DATABASE_URL });
const tenants = [
  {
    tenantId: config.PR01_TENANT_A_ID,
    customerId: config.PR01_CUSTOMER_A_ID,
    makerId: "11111111-1111-4111-8111-111111111151",
    checkerId: "11111111-1111-4111-8111-111111111152",
    correlationId: "11111111-1111-4111-8111-111111111153",
    suffix: "A",
  },
  {
    tenantId: config.PR01_TENANT_B_ID,
    customerId: config.PR01_CUSTOMER_B_ID,
    makerId: "22222222-2222-4222-8222-222222222251",
    checkerId: "22222222-2222-4222-8222-222222222252",
    correlationId: "22222222-2222-4222-8222-222222222253",
    suffix: "B",
  },
] as const;

const productDefinitions: ReadonlyArray<{
  type: ProductType;
  name: string;
  terms: ProductVersionTerms;
}> = [
  {
    type: "ORDINARY",
    name: "Ordinary Savings",
    terms: {
      productType: "ORDINARY",
      annualRate: "4.0000000000",
      currency: "NGN",
      minimumDepositMinor: "0",
      calculationMethod: "DAILY_BALANCE",
      paymentFrequency: "MONTHLY",
      dayCountBasis: "ACT_365_FIXED",
      compoundingMethod: "MONTHLY",
      withdrawalAllowed: true,
      earlyWithdrawalAllowed: true,
    },
  },
  {
    type: "TARGET",
    name: "Target Savings",
    terms: {
      productType: "TARGET",
      annualRate: "12.0000000000",
      currency: "NGN",
      minimumDepositMinor: "100000",
      calculationMethod: "DAILY_BALANCE",
      paymentFrequency: "AT_MATURITY",
      dayCountBasis: "ACT_365_FIXED",
      compoundingMethod: "SIMPLE",
      withdrawalAllowed: false,
      earlyWithdrawalAllowed: true,
      partialWithdrawalLimitPercent: "50",
      partialWithdrawalCount: 1,
      withdrawnInterestForfeiture: true,
      breakForfeitsAllInterest: true,
    },
  },
  {
    type: "FIXED_DEPOSIT",
    name: "Fixed Deposit",
    terms: {
      productType: "FIXED_DEPOSIT",
      annualRate: "10.0000000000",
      currency: "NGN",
      minimumDepositMinor: "1000000",
      calculationMethod: "FIXED",
      paymentFrequency: "AT_MATURITY",
      dayCountBasis: "ACT_365_FIXED",
      compoundingMethod: "SIMPLE",
      withdrawalAllowed: false,
      earlyWithdrawalAllowed: true,
      earlyLiquidationPenaltyRate: "2.0000000000",
      minimumTenureDays: 30,
      maximumTenureDays: 365,
    },
  },
  {
    type: "RECURRING",
    name: "Recurring Contributions",
    terms: {
      productType: "RECURRING",
      annualRate: "5.0000000000",
      currency: "NGN",
      minimumDepositMinor: "10000",
      calculationMethod: "DAILY_BALANCE",
      paymentFrequency: "MONTHLY",
      dayCountBasis: "ACT_365_FIXED",
      compoundingMethod: "MONTHLY",
      withdrawalAllowed: true,
      contributionFrequencies: ["DAILY", "WEEKLY", "MONTHLY"],
    },
  },
];

try {
  let approvalContext: (typeof tenants)[number] = tenants[0];
  const products = new SavingsProductService(database, {
    consume: (input) =>
      Promise.resolve({
        approvalId: input.approvalId,
        makerId: approvalContext.makerId,
        checkerIds: [approvalContext.checkerId],
        authorityLevel: 1,
        replayed: false,
      }),
  });
  const ordinaryAccounts = new OrdinarySavingsService(
    database,
    new LedgerClient(
      config.LEDGER_URL,
      await ParcTokenClient.fromBase64Key({
        tokenUrl: config.AUTH_TOKEN_URL,
        issuer: config.AUTH_JWT_ISSUER,
        clientId: "parc-savings",
        keyId: config.SERVICE_CLIENT_KEY_ID,
        privateKeyBase64: config.SERVICE_CLIENT_PRIVATE_KEY_BASE64,
      }),
    ),
  );
  const output = [];

  for (const tenant of tenants) {
    approvalContext = tenant;
    const versions = new Map<ProductType, string>();
    for (const definition of productDefinitions) {
      const key = definition.type.toLowerCase().replaceAll("_", "-");
      const product = await products.createProduct({
        tenantId: tenant.tenantId,
        code: `PR01_${definition.type}_${tenant.suffix}`,
        name: `PR-01 ${definition.name}`,
        productType: definition.type,
        description: "Disposable load and resilience fixture",
        idempotencyKey: `pr01-${key}-product-v1`,
      });
      const version = await products.createVersion({
        tenantId: tenant.tenantId,
        productId: product.id,
        terms: definition.terms,
        effectiveFrom: "2026-01-01T00:00:00.000Z",
        createdBy: tenant.makerId,
        idempotencyKey: `pr01-${key}-version-v1`,
      });
      await products.publish({
        tenantId: tenant.tenantId,
        productId: product.id,
        versionId: version.id,
        approvalId:
          tenant.suffix === "A"
            ? `11111111-1111-4111-8111-11111111${String(1154 + productDefinitions.indexOf(definition)).padStart(4, "0")}`
            : `22222222-2222-4222-8222-22222222${String(2254 + productDefinitions.indexOf(definition)).padStart(4, "0")}`,
        publisherId: tenant.checkerId,
        idempotencyKey: `pr01-${key}-publication-v1`,
        correlationId: tenant.correlationId,
      });
      versions.set(definition.type, version.id);
    }

    const ordinaryVersionId = versions.get("ORDINARY");
    if (!ordinaryVersionId)
      throw new Error("Ordinary savings fixture version was not created");
    const account = await ordinaryAccounts.openAccount({
      tenantId: tenant.tenantId,
      customerId: tenant.customerId,
      productVersionId: ordinaryVersionId,
      currency: "NGN",
      acceptedAt: "2026-09-15T09:00:00.000Z",
      acceptanceReference: `PR01-NONREGULATORY-SAVINGS-${tenant.suffix}`,
      correlationId: tenant.correlationId,
      idempotencyKey: "pr01-ordinary-account-v1",
    });
    output.push({
      tenantId: tenant.tenantId,
      customerId: tenant.customerId,
      publishedProductTypes: productDefinitions.map(({ type }) => type),
      ordinaryAccountId: account.id,
      ordinaryLedgerAccountPurpose: "ORDINARY_SAVINGS",
      accountStatus: account.status,
      currency: "NGN",
    });
  }

  console.log(JSON.stringify({ fixture: "PR-01", savings: output }));
} finally {
  await database.destroy();
}
