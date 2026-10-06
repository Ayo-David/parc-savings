import { jest } from "@jest/globals";
import { LedgerClient } from "../src/runtime/ledger-client.js";

describe("LedgerClient", () => {
  const originalFetch = global.fetch;
  afterEach(() => {
    global.fetch = originalFetch;
  });

  it.each([
    ["balance read", "getBalance", "ledger.balances.read"],
    ["account provisioning", "provisionAccount", "ledger.accounts.provision"],
  ] as const)(
    "requests an Auth token scoped to the %s",
    async (_name, method, scope) => {
      const fetchMock = jest.fn<typeof fetch>(() =>
        Promise.resolve(
          Response.json({
            account_id: "22222222-2222-4222-8222-222222222222",
            posted_balance_minor: "100",
            held_balance_minor: "0",
            available_balance_minor: "100",
            version: 1,
          }),
        ),
      );
      global.fetch = fetchMock;
      const authorization = jest.fn(() =>
        Promise.resolve("Bearer issued-ledger-token"),
      );
      const client = new LedgerClient("http://ledger.test", { authorization });
      const tenantId = "11111111-1111-4111-8111-111111111111";
      if (method === "getBalance")
        await client.getBalance({
          tenantId,
          accountId: "22222222-2222-4222-8222-222222222222",
        });
      else
        await client.provisionAccount({
          tenantId,
          customerId: "33333333-3333-4333-8333-333333333333",
          purpose: "ORDINARY_SAVINGS",
          currency: "NGN",
          idempotencyKey: "provision-1",
        });
      expect(authorization).toHaveBeenCalledWith({
        audience: "parc-ledger",
        scopes: [scope],
        tenantId,
      });
      const headers = new Headers(fetchMock.mock.calls[0]?.[1]?.headers);
      expect(headers.get("authorization")).toBe("Bearer issued-ledger-token");
      expect(headers.get("x-calling-service")).toBe("parc-savings");
      expect(headers.get("x-internal-service-token")).toBeNull();
    },
  );
});
