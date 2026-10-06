import type { RequestHandler } from "express";
import type { SavingsAccess } from "../../src/app.js";
import {
  authorize,
  type AccessPolicy,
  type ParcPrincipal,
} from "../../src/security/parc-service-auth.js";

/**
 * For HTTP tests that exercise domain behaviour: grants each route the
 * principal its policy expects (customer via Mobile BFF, administrator via
 * Admin BFF, or a service token) and still runs the real policy check.
 */
export function testAccess(identity: {
  tenantId: string;
  customerId: string;
  adminId?: string;
}): SavingsAccess {
  return {
    require(policy: AccessPolicy): RequestHandler {
      return (request, _response, next) => {
        const delegatedAs = policy.subjectTypes?.[0];
        const base = {
          tenantId: identity.tenantId,
          scopes: new Set(policy.scopes),
          token: "test",
          expiresAt: Math.floor(Date.now() / 1000) + 300,
        };
        const principal: ParcPrincipal =
          policy.kinds?.includes("delegated") === false || !delegatedAs
            ? { ...base, kind: "service", client: "parc-test", actors: [] }
            : {
                ...base,
                kind: "delegated",
                client: policy.actors?.[0] ?? "parc-test",
                actors: [policy.actors?.[0] ?? "parc-test"],
                subject: {
                  id:
                    delegatedAs === "ADMINISTRATOR"
                      ? (identity.adminId ?? identity.customerId)
                      : identity.customerId,
                  type: delegatedAs,
                  sessionId: "00000000-0000-4000-8000-000000000000",
                },
              };
        authorize(principal, policy);
        request.parcPrincipal = principal;
        next();
      };
    },
  };
}
