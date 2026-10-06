import { createHash, randomUUID } from "node:crypto";
import type { Knex } from "knex";
import { withTenantTransaction } from "../database/client.js";
import type { SavingsApprovalGateway } from "./approval-gateway.js";

export type ProductType = "ORDINARY" | "TARGET" | "FIXED_DEPOSIT" | "RECURRING";
export interface ProductVersionTerms {
  productType: ProductType;
  annualRate: string;
  currency: "NGN";
  minimumBalanceMinor?: string;
  minimumDepositMinor: string;
  maximumBalanceMinor?: string;
  calculationMethod: "DAILY_BALANCE" | "AVERAGE_DAILY_BALANCE" | "FIXED";
  paymentFrequency:
    "DAILY" | "MONTHLY" | "QUARTERLY" | "ANNUALLY" | "AT_MATURITY";
  dayCountBasis: "ACT_365_FIXED" | "ACT_ACT" | "ACT_360" | "30_360";
  compoundingMethod: "SIMPLE" | "DAILY" | "MONTHLY" | "QUARTERLY" | "ANNUALLY";
  withdrawalAllowed?: boolean;
  earlyWithdrawalAllowed?: boolean;
  lockPeriodDays?: number;
  contributionFrequencies?: string[];
  partialWithdrawalLimitPercent?: string;
  partialWithdrawalCount?: number;
  withdrawnInterestForfeiture?: boolean;
  breakForfeitsAllInterest?: boolean;
  earlyLiquidationPenaltyRate?: string;
  minimumTenureDays?: number;
  maximumTenureDays?: number;
}

export class SavingsProductService {
  public constructor(
    private readonly database: Knex,
    private readonly approvals: SavingsApprovalGateway,
  ) {}
  public async createProduct(input: {
    tenantId: string;
    code: string;
    name: string;
    productType: ProductType;
    description?: string;
    idempotencyKey: string;
  }): Promise<{ id: string; status: "DRAFT"; replayed: boolean }> {
    const requestHash = hash({
      code: input.code,
      name: input.name,
      productType: input.productType,
      description: input.description ?? null,
    });
    return withTenantTransaction(
      this.database,
      input.tenantId,
      async (transaction) => {
        const existing = await transaction("savings_products")
          .where({
            tenant_id: input.tenantId,
            idempotency_key: input.idempotencyKey,
          })
          .first<{ id: string; request_hash: string }>();
        if (existing) {
          if (existing.request_hash !== requestHash)
            throw new Error(
              "Idempotency key reused with a different savings product",
            );
          return { id: existing.id, status: "DRAFT", replayed: true };
        }
        const id = randomUUID();
        await transaction("savings_products").insert({
          id,
          tenant_id: input.tenantId,
          product_code: input.code,
          product_name: input.name,
          product_type: input.productType,
          description: input.description ?? null,
          currency: "NGN",
          minimum_balance: 0,
          minimum_deposit: 0,
          interest_rate: 0,
          lifecycle_status: "DRAFT",
          is_active: false,
          idempotency_key: input.idempotencyKey,
          request_hash: requestHash,
        });
        return { id, status: "DRAFT", replayed: false };
      },
    );
  }
  public async createVersion(input: {
    tenantId: string;
    productId: string;
    terms: ProductVersionTerms;
    effectiveFrom: string;
    createdBy: string;
    idempotencyKey: string;
  }): Promise<{
    id: string;
    version: number;
    status: "DRAFT";
    replayed: boolean;
  }> {
    validateTerms(input.terms);
    const requestHash = hash({
      productId: input.productId,
      terms: input.terms,
      effectiveFrom: input.effectiveFrom,
    });
    return withTenantTransaction(
      this.database,
      input.tenantId,
      async (transaction) => {
        const existing = await transaction("savings_product_versions")
          .where({
            tenant_id: input.tenantId,
            idempotency_key: input.idempotencyKey,
          })
          .first<{
            id: string;
            version_number: number;
            request_hash: string;
          }>();
        if (existing) {
          if (existing.request_hash !== requestHash)
            throw new Error(
              "Idempotency key reused with a different savings product version",
            );
          return {
            id: existing.id,
            version: existing.version_number,
            status: "DRAFT",
            replayed: true,
          };
        }
        const product = await transaction("savings_products")
          .where({
            tenant_id: input.tenantId,
            id: input.productId,
            deleted_at: null,
          })
          .forUpdate()
          .first<{ product_type: ProductType }>();
        if (!product || product.product_type !== input.terms.productType)
          throw new Error("Savings product not found or product type mismatch");
        const sequence = await transaction("savings_product_versions")
          .where({
            tenant_id: input.tenantId,
            savings_product_id: input.productId,
          })
          .max<{ maximum: string | null }>("version_number as maximum")
          .first();
        const version = Number(sequence?.maximum ?? 0) + 1;
        const id = randomUUID();
        await transaction("savings_product_versions").insert({
          id,
          tenant_id: input.tenantId,
          savings_product_id: input.productId,
          version_number: version,
          status: "DRAFT",
          effective_from: input.effectiveFrom,
          currency: input.terms.currency,
          product_type: input.terms.productType,
          minimum_balance: input.terms.minimumBalanceMinor ?? null,
          minimum_deposit: input.terms.minimumDepositMinor,
          maximum_balance: input.terms.maximumBalanceMinor ?? null,
          annual_rate: input.terms.annualRate,
          calculation_method: input.terms.calculationMethod,
          payment_frequency: input.terms.paymentFrequency,
          day_count_basis: input.terms.dayCountBasis,
          compounding_method: input.terms.compoundingMethod,
          withdrawal_allowed: input.terms.withdrawalAllowed ?? true,
          early_withdrawal_allowed: input.terms.earlyWithdrawalAllowed ?? false,
          lock_period_days: input.terms.lockPeriodDays ?? 0,
          terms: input.terms,
          terms_hash: hash(input.terms),
          created_by: input.createdBy,
          idempotency_key: input.idempotencyKey,
          request_hash: requestHash,
        });
        if (input.terms.productType === "FIXED_DEPOSIT") {
          await transaction("fixed_deposit_rates").insert({
            tenant_id: input.tenantId,
            savings_product_id: input.productId,
            product_version_id: id,
            tenure_days: input.terms.minimumTenureDays,
            interest_rate: input.terms.annualRate,
            minimum_amount: input.terms.minimumDepositMinor,
            maximum_amount: input.terms.maximumBalanceMinor ?? null,
            effective_from: input.effectiveFrom,
          });
        } else {
          await transaction("savings_product_rates").insert({
            tenant_id: input.tenantId,
            savings_product_id: input.productId,
            product_version_id: id,
            interest_rate: input.terms.annualRate,
            minimum_balance: input.terms.minimumBalanceMinor ?? null,
            maximum_balance: input.terms.maximumBalanceMinor ?? null,
            effective_from: input.effectiveFrom,
          });
        }
        return { id, version, status: "DRAFT", replayed: false };
      },
    );
  }
  public async publish(input: {
    tenantId: string;
    productId: string;
    versionId: string;
    approvalId: string;
    publisherId: string;
    idempotencyKey: string;
    correlationId: string;
  }): Promise<{ id: string; status: "PUBLISHED"; replayed: boolean }> {
    const publicationRequestHash = hash({
      productId: input.productId,
      versionId: input.versionId,
      approvalId: input.approvalId,
      publisherId: input.publisherId,
    });
    const version = await withTenantTransaction(
      this.database,
      input.tenantId,
      (transaction) =>
        transaction("savings_product_versions")
          .where({
            tenant_id: input.tenantId,
            id: input.versionId,
            savings_product_id: input.productId,
          })
          .first<{
            status: string;
            terms_hash: string;
            created_by: string;
            product_type: ProductType;
            approval_id: string | null;
            published_by: string | null;
            publication_idempotency_key: string | null;
            publication_request_hash: string | null;
          }>(),
    );
    if (!version) throw new Error("Savings product version not found");
    if (version.status === "PUBLISHED") {
      if (
        version.publication_idempotency_key !== input.idempotencyKey ||
        version.publication_request_hash !== publicationRequestHash ||
        version.approval_id !== input.approvalId ||
        version.published_by !== input.publisherId
      )
        throw new Error("Publication idempotency conflict");
      return { id: input.versionId, status: "PUBLISHED", replayed: true };
    }
    if (version.status !== "DRAFT" && version.status !== "PENDING_APPROVAL")
      throw new Error("Savings product version cannot be published");
    const payloadHash = hash({
      productId: input.productId,
      versionId: input.versionId,
      termsHash: version.terms_hash,
    });
    const approval = await this.approvals.consume({
      tenantId: input.tenantId,
      approvalId: input.approvalId,
      action: "PRODUCT_PUBLICATION",
      resourceType: "savings_product_version",
      resourceId: input.versionId,
      payloadHash,
      idempotencyKey: `savings-publish:${input.idempotencyKey}:approval`,
      correlationId: input.correlationId,
    });
    if (approval.makerId !== version.created_by)
      throw new Error("Approval maker must be the product version creator");
    if (approval.checkerIds.includes(approval.makerId))
      throw new Error("Maker cannot approve product publication");
    return withTenantTransaction(
      this.database,
      input.tenantId,
      async (transaction) => {
        await transaction("savings_product_versions")
          .where({
            tenant_id: input.tenantId,
            savings_product_id: input.productId,
            is_current: true,
          })
          .update({
            status: "RETIRED",
            is_current: false,
            effective_to: transaction.fn.now(),
          });
        const changed = await transaction("savings_product_versions")
          .where({ tenant_id: input.tenantId, id: input.versionId })
          .whereIn("status", ["DRAFT", "PENDING_APPROVAL"])
          .update({
            status: "PUBLISHED",
            is_current: true,
            approval_id: approval.approvalId,
            approval_payload_hash: payloadHash,
            approval_maker_id: approval.makerId,
            approval_checker_ids: approval.checkerIds,
            approved_authority_level: approval.authorityLevel,
            approved_by: approval.checkerIds[0],
            published_by: input.publisherId,
            published_at: transaction.fn.now(),
            publication_idempotency_key: input.idempotencyKey,
            publication_request_hash: publicationRequestHash,
          });
        if (changed !== 1)
          throw new Error("Savings product version publication conflict");
        await transaction("savings_products")
          .where({ tenant_id: input.tenantId, id: input.productId })
          .update({ lifecycle_status: "ACTIVE", is_active: true });
        await transaction("savings_outbox_events").insert({
          tenant_id: input.tenantId,
          aggregate_type: "savings_product_version",
          aggregate_id: input.versionId,
          aggregate_version: 1,
          event_type: "savings.product-version-published.v1",
          event_version: 1,
          correlation_id: input.correlationId,
          partition_key: `${input.tenantId}:${input.productId}`,
          payload: {
            product_id: input.productId,
            product_version_id: input.versionId,
            product_type: version.product_type,
            currency: "NGN",
            terms_hash: version.terms_hash,
            approval_id: approval.approvalId,
          },
        });
        return { id: input.versionId, status: "PUBLISHED", replayed: false };
      },
    );
  }
}

function validateTerms(terms: ProductVersionTerms): void {
  if (!/^(0|[1-9][0-9]*)(\.[0-9]{1,10})?$/.test(terms.annualRate))
    throw new Error("Annual rate requires at most ten decimal places");
  if (terms.currency !== "NGN")
    throw new Error("Only NGN is operationally enabled");
  if (
    terms.maximumBalanceMinor &&
    BigInt(terms.maximumBalanceMinor) <= BigInt(terms.minimumBalanceMinor ?? 0)
  )
    throw new Error("Maximum balance must exceed minimum balance");
  if (
    terms.productType === "ORDINARY" &&
    terms.minimumBalanceMinor !== undefined
  )
    throw new Error("Ordinary savings cannot configure a minimum balance");
  if (
    terms.productType === "TARGET" &&
    (terms.partialWithdrawalLimitPercent !== "50" ||
      terms.partialWithdrawalCount !== 1 ||
      terms.withdrawnInterestForfeiture !== true ||
      terms.breakForfeitsAllInterest !== true ||
      terms.earlyWithdrawalAllowed !== true)
  )
    throw new Error(
      "Target savings requires the approved early-withdrawal policy",
    );
  if (
    terms.productType === "FIXED_DEPOSIT" &&
    (terms.earlyWithdrawalAllowed !== true ||
      terms.earlyLiquidationPenaltyRate === undefined ||
      !terms.minimumTenureDays ||
      !terms.maximumTenureDays ||
      terms.maximumTenureDays < terms.minimumTenureDays)
  )
    throw new Error(
      "Fixed deposit requires valid tenure and early-liquidation penalty terms",
    );
  if (
    terms.productType === "RECURRING" &&
    !terms.contributionFrequencies?.length
  )
    throw new Error("Recurring savings requires contribution frequencies");
}
function hash(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex");
}
