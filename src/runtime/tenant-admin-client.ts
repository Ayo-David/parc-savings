import type { ParcTokenClient } from "../security/parc-service-auth.js";
import type { SavingsApprovalGateway } from "../services/approval-gateway.js";

export class TenantAdminClient implements SavingsApprovalGateway {
  public constructor(
    private readonly baseUrl: string,
    private readonly tokens: Pick<ParcTokenClient, "authorization">,
    private readonly timeoutMs = 5_000,
  ) {}

  public async consume(
    input: Parameters<SavingsApprovalGateway["consume"]>[0],
  ): ReturnType<SavingsApprovalGateway["consume"]> {
    const response = await fetch(
      `${this.baseUrl}/internal/v1/approvals/${input.approvalId}/consume`,
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: await this.tokens.authorization({
            audience: "parc-tenant-admin",
            scopes: ["tenant.approvals.consume"],
            tenantId: input.tenantId,
          }),
          "x-calling-service": "parc-savings",
          "x-tenant-id": input.tenantId,
          "idempotency-key": input.idempotencyKey,
          "x-correlation-id": input.correlationId,
        },
        body: JSON.stringify({
          action: input.action,
          resource_type: input.resourceType,
          resource_id: input.resourceId,
          payload_hash: input.payloadHash,
        }),
        signal: AbortSignal.timeout(this.timeoutMs),
      },
    );
    const body = (await response.json()) as Record<string, unknown>;
    if (!response.ok)
      throw new Error(
        `Tenant Admin approval request failed (${response.status})`,
      );
    if (
      typeof body.id !== "string" ||
      typeof body.maker_id !== "string" ||
      !Array.isArray(body.checker_ids) ||
      typeof body.approved_authority_level !== "number"
    )
      throw new Error("Tenant Admin returned incomplete approval evidence");
    return {
      approvalId: body.id,
      makerId: body.maker_id,
      checkerIds: body.checker_ids.map(String),
      authorityLevel: body.approved_authority_level,
      replayed: body.replayed === true,
    };
  }
}
