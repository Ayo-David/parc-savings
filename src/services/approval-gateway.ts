export interface SavingsApprovalGateway {
  consume(input: {
    tenantId: string;
    approvalId: string;
    action: "PRODUCT_PUBLICATION";
    resourceType: "savings_product_version";
    resourceId: string;
    payloadHash: string;
    idempotencyKey: string;
    correlationId: string;
  }): Promise<{
    approvalId: string;
    makerId: string;
    checkerIds: string[];
    authorityLevel: number;
    replayed: boolean;
  }>;
}
