import { randomUUID } from "node:crypto";
import { jest } from "@jest/globals";
import request from "supertest";
import { createApp } from "../src/app.js";
import { testAccess } from "./support/test-access.js";
import type { SavingsProductService } from "../src/services/savings-product-service.js";
import type { SavingsSummaryService } from "../src/services/savings-summary-service.js";

describe("customer savings summary HTTP boundary", () => {
  it("uses the authenticated customer subject and returns contract-shaped balances", async () => {
    const tenantId = randomUUID();
    const customerId = randomUUID();
    const accountId = randomUUID();
    const versionId = randomUUID();
    const get = jest.fn(() =>
      Promise.resolve({
        accounts: [
          {
            savings_account_id: accountId,
            account_number: "SVG000000000001",
            product_type: "ORDINARY" as const,
            product_version_id: versionId,
            currency: "NGN" as const,
            status: "ACTIVE",
            posted_balance_minor: "0",
            held_balance_minor: "0",
            available_balance_minor: "0",
          },
        ],
        totals: [
          {
            currency: "NGN" as const,
            posted_balance_minor: "0",
            held_balance_minor: "0",
            available_balance_minor: "0",
          },
        ],
      }),
    );
    const app = createApp(
      {} as SavingsProductService,
      testAccess({ tenantId, customerId: customerId, adminId: customerId }),
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      { get } as unknown as SavingsSummaryService,
    );

    const response = await request(app)
      .get("/v1/customer/savings-summary")
      .set("authorization", "Bearer test")
      .set("x-tenant-id", tenantId);

    expect(response.status).toBe(200);
    expect(response.body).toMatchObject({
      accounts: [{ savings_account_id: accountId, currency: "NGN" }],
      totals: [{ available_balance_minor: "0", currency: "NGN" }],
    });
    expect(get).toHaveBeenCalledWith({ tenantId, customerId });
  });
});
