import { createServer } from "node:http";
import { z } from "zod";
import { createApp } from "./app.js";
import { createDatabase } from "./database/client.js";
import { LedgerClient } from "./runtime/ledger-client.js";
import { TenantAdminClient } from "./runtime/tenant-admin-client.js";
import { SavingsProductService } from "./services/savings-product-service.js";
import { TargetSavingsService } from "./services/target-savings-service.js";
import { OrdinarySavingsService } from "./services/ordinary-savings-service.js";
import { FixedDepositService } from "./services/fixed-deposit-service.js";
import { RecurringContributionService } from "./services/recurring-contribution-service.js";
import { InterestService } from "./services/interest-service.js";
import { SavingsSummaryService } from "./services/savings-summary-service.js";
import {
  createParcAuth,
  ParcTokenClient,
} from "./security/parc-service-auth.js";

const config = z
  .object({
    PORT: z.coerce.number().int().positive().default(3006),
    HOST: z.string().default("0.0.0.0"),
    DATABASE_URL: z.string().default("postgresql:///parc_savings"),
    AUTH_JWKS_URL: z
      .string()
      .url()
      .default("http://127.0.0.1:3001/.well-known/jwks.json"),
    AUTH_JWT_ISSUER: z.string().url().default("https://auth.parc.invalid"),
    AUTH_TOKEN_URL: z
      .string()
      .url()
      .default("http://127.0.0.1:3001/internal/v1/oauth/token"),
    SERVICE_CLIENT_KEY_ID: z.string().min(1),
    SERVICE_CLIENT_PRIVATE_KEY_BASE64: z.string().min(1),
    TENANT_ADMIN_URL: z.string().url().default("http://127.0.0.1:3002"),
    LEDGER_URL: z.string().url().default("http://127.0.0.1:3003"),
  })
  .parse(process.env);
const database = createDatabase(config.DATABASE_URL);
// Outbound: short-lived tokens from Auth, authenticated with this service's key.
const tokens = await ParcTokenClient.fromBase64Key({
  tokenUrl: config.AUTH_TOKEN_URL,
  issuer: config.AUTH_JWT_ISSUER,
  clientId: "parc-savings",
  keyId: config.SERVICE_CLIENT_KEY_ID,
  privateKeyBase64: config.SERVICE_CLIENT_PRIVATE_KEY_BASE64,
});
// Inbound: tokens issued for the parc-savings audience.
const access = createParcAuth({
  issuer: config.AUTH_JWT_ISSUER,
  audience: "parc-savings",
  jwksUrl: config.AUTH_JWKS_URL,
});
const approvals = new TenantAdminClient(config.TENANT_ADMIN_URL, tokens);
const ledger = new LedgerClient(config.LEDGER_URL, tokens);
const ordinary = new OrdinarySavingsService(database, ledger);
const app = createApp(
  new SavingsProductService(database, approvals),
  access,
  ordinary,
  new TargetSavingsService(database, ledger),
  new FixedDepositService(database, ledger),
  new RecurringContributionService(database, ledger, ordinary),
  new InterestService(database, ledger),
  new SavingsSummaryService(database, ledger),
);
const server = createServer(app);
server.listen(config.PORT, config.HOST);
process.on("SIGTERM", () => server.close(() => void database.destroy()));
