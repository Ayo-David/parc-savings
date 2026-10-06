import express, {
  type NextFunction,
  type Request,
  type RequestHandler,
  type Response,
} from "express";
import helmet from "helmet";
import { z } from "zod";
import type { SavingsProductService } from "./services/savings-product-service.js";
import type { OrdinarySavingsService } from "./services/ordinary-savings-service.js";
import type { TargetSavingsService } from "./services/target-savings-service.js";
import type { FixedDepositService } from "./services/fixed-deposit-service.js";
import type { RecurringContributionService } from "./services/recurring-contribution-service.js";
import type { InterestService } from "./services/interest-service.js";
import type { SavingsSummaryService } from "./services/savings-summary-service.js";
import {
  ParcAuthError,
  principalOf,
  type AccessPolicy,
} from "./security/parc-service-auth.js";

/** Inbound Auth-issued token validation (see parc-service-auth). */
export interface SavingsAccess {
  require(policy: AccessPolicy): RequestHandler;
}

/**
 * Savings endpoint permissions. Each route authorizes both the user (`sub`,
 * `subject_type`) and the acting service (`client_id`) from one token.
 */
export const savingsAccessPolicies = {
  customerRead: {
    scopes: ["savings.customer.read"],
    kinds: ["delegated"],
    subjectTypes: ["CUSTOMER"],
    actors: ["parc-mobile-bff"],
  },
  customerWrite: {
    scopes: ["savings.customer.write"],
    kinds: ["delegated"],
    subjectTypes: ["CUSTOMER"],
    actors: ["parc-mobile-bff"],
  },
  productsManage: {
    scopes: ["savings.products.manage"],
    kinds: ["delegated"],
    subjectTypes: ["ADMINISTRATOR"],
    actors: ["parc-admin-bff"],
  },
  productsPublish: {
    scopes: ["savings.products.publish"],
    kinds: ["delegated"],
    subjectTypes: ["ADMINISTRATOR"],
    actors: ["parc-admin-bff"],
  },
  /** Background processing: a service token, or an administrator via the Admin BFF. */
  operations: {
    scopes: ["savings.operations.process"],
    subjectTypes: ["ADMINISTRATOR"],
  },
} satisfies Record<string, AccessPolicy>;
const productInput = z
  .object({
    code: z.string().regex(/^[A-Z][A-Z0-9_-]{1,49}$/),
    name: z.string().min(2).max(150),
    product_type: z.enum(["ORDINARY", "TARGET", "FIXED_DEPOSIT", "RECURRING"]),
    description: z.string().max(2000).optional(),
  })
  .strict();
const versionInput = z
  .object({
    product_type: z.enum(["ORDINARY", "TARGET", "FIXED_DEPOSIT", "RECURRING"]),
    annual_rate: z.string().regex(/^(0|[1-9][0-9]*)(\.[0-9]{1,10})?$/),
    currency: z.literal("NGN"),
    minimum_balance_minor: z
      .string()
      .regex(/^(0|[1-9][0-9]*)$/)
      .optional(),
    minimum_deposit_minor: z.string().regex(/^(0|[1-9][0-9]*)$/),
    maximum_balance_minor: z
      .string()
      .regex(/^[1-9][0-9]*$/)
      .optional(),
    calculation_method: z.enum([
      "DAILY_BALANCE",
      "AVERAGE_DAILY_BALANCE",
      "FIXED",
    ]),
    payment_frequency: z.enum([
      "DAILY",
      "MONTHLY",
      "QUARTERLY",
      "ANNUALLY",
      "AT_MATURITY",
    ]),
    day_count_basis: z.enum(["ACT_365_FIXED", "ACT_ACT", "ACT_360", "30_360"]),
    compounding_method: z.enum([
      "SIMPLE",
      "DAILY",
      "MONTHLY",
      "QUARTERLY",
      "ANNUALLY",
    ]),
    withdrawal_allowed: z.boolean().optional(),
    early_withdrawal_allowed: z.boolean().optional(),
    lock_period_days: z.number().int().nonnegative().optional(),
    effective_from: z.string().datetime(),
    contribution_frequencies: z
      .array(z.enum(["DAILY", "WEEKLY", "BIWEEKLY", "MONTHLY", "QUARTERLY"]))
      .min(1)
      .optional(),
    partial_withdrawal_limit_percent: z.literal("50").optional(),
    partial_withdrawal_count: z.literal(1).optional(),
    withdrawn_interest_forfeiture: z.boolean().optional(),
    break_forfeits_all_interest: z.boolean().optional(),
    early_liquidation_penalty_rate: z
      .string()
      .regex(/^(0|[1-9][0-9]*)(\.[0-9]{1,10})?$/)
      .optional(),
    minimum_tenure_days: z.number().int().positive().optional(),
    maximum_tenure_days: z.number().int().positive().optional(),
  })
  .strict();
const publishInput = z
  .object({
    version_id: z.string().uuid(),
    approval_id: z.string().uuid(),
    publisher_id: z.string().uuid(),
    correlation_id: z.string().uuid(),
  })
  .strict();
const accountInput = z
  .object({
    customer_id: z.string().uuid(),
    product_version_id: z.string().uuid(),
    currency: z.literal("NGN"),
    accepted_at: z.string().datetime(),
    acceptance_reference: z.string().min(1).max(255),
    correlation_id: z.string().uuid(),
  })
  .strict();
const contributionInput = z
  .object({
    amount_minor: z.string().regex(/^[1-9][0-9]*$/),
    currency: z.literal("NGN"),
    goal_id: z.string().uuid().optional(),
    correlation_id: z.string().uuid(),
  })
  .strict();
const goalInput = z
  .object({
    customer_id: z.string().uuid(),
    savings_account_id: z.string().uuid(),
    name: z.string().min(1).max(150),
    target_amount_minor: z.string().regex(/^[1-9][0-9]*$/),
    currency: z.literal("NGN"),
    target_date: z.string().date(),
    correlation_id: z.string().uuid(),
  })
  .strict();
const goalPartialInput = z
  .object({
    amount_minor: z.string().regex(/^[1-9][0-9]*$/),
    currency: z.literal("NGN"),
    correlation_id: z.string().uuid(),
  })
  .strict();
const goalBreakInput = z
  .object({ currency: z.literal("NGN"), correlation_id: z.string().uuid() })
  .strict();
const fixedDepositInput = z
  .object({
    product_version_id: z.string().uuid(),
    amount_minor: z.string().regex(/^[1-9][0-9]*$/),
    currency: z.literal("NGN"),
    tenure_days: z.number().int().positive(),
    quote_id: z.string().uuid(),
    quote_hash: z.string().regex(/^[a-f0-9]{64}$/),
    accepted_at: z.string().datetime(),
    acceptance_reference: z.string().min(1).max(255),
    correlation_id: z.string().uuid(),
  })
  .strict();
const fixedDepositSettlementInput = z
  .object({ currency: z.literal("NGN"), correlation_id: z.string().uuid() })
  .strict();
const fixedDepositLiquidationInput = fixedDepositSettlementInput
  .extend({
    quote_id: z.string().uuid(),
    quote_hash: z.string().regex(/^[a-f0-9]{64}$/),
  })
  .strict();
const fixedDepositQuoteInput = z
  .object({
    product_version_id: z.string().uuid(),
    principal_minor: z.string().regex(/^[1-9][0-9]*$/),
    currency: z.literal("NGN"),
    tenor_days: z.number().int().positive(),
    correlation_id: z.string().uuid(),
  })
  .strict();
const maturityInstructionInput = z
  .object({
    instruction: z.enum([
      "payout",
      "renew_principal",
      "renew_principal_and_interest",
    ]),
    renewal_tenure_days: z.number().int().positive().optional(),
    currency: z.literal("NGN"),
    correlation_id: z.string().uuid(),
  })
  .strict();
const recurringPlanInput = z
  .object({
    savings_account_id: z.string().uuid(),
    goal_id: z.string().uuid().optional(),
    amount_minor: z.string().regex(/^[1-9][0-9]*$/),
    currency: z.literal("NGN"),
    frequency: z.enum(["DAILY", "WEEKLY", "MONTHLY"]),
    start_date: z.string().date(),
    end_date: z.string().date().optional(),
    max_executions: z.number().int().positive().optional(),
    execution_time: z
      .string()
      .regex(/^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/)
      .default("08:00:00"),
    timezone: z.string().min(1).max(100).default("Africa/Lagos"),
    consent_reference: z.string().min(1).max(255),
    correlation_id: z.string().uuid(),
    source: z.literal("WALLET").default("WALLET"),
  })
  .strict();
const recurringExecutionInput = z
  .object({
    scheduled_date: z.string().date(),
    correlation_id: z.string().uuid(),
    worker_id: z.string().min(1).max(100),
  })
  .strict();
const interestAccrualInput = z
  .object({
    savings_account_id: z.string().uuid(),
    accrual_date: z.string().date(),
    currency: z.literal("NGN"),
    correlation_id: z.string().uuid(),
  })
  .strict();
const interestPaymentInput = z
  .object({
    savings_account_id: z.string().uuid(),
    period_start: z.string().date(),
    period_end: z.string().date(),
    currency: z.literal("NGN"),
    correlation_id: z.string().uuid(),
  })
  .strict();

export function createApp(
  products: SavingsProductService,
  access: SavingsAccess,
  ordinary?: OrdinarySavingsService,
  targets?: TargetSavingsService,
  fixedDeposits?: FixedDepositService,
  recurring?: RecurringContributionService,
  interest?: InterestService,
  summaries?: SavingsSummaryService,
) {
  const app = express();
  app.disable("x-powered-by");
  app.use(helmet());
  app.use(express.json({ limit: "256kb" }));
  app.get("/health", (_request, response) =>
    response.status(200).json({ status: "UP", service: "parc-savings" }),
  );
  app.get(
    "/v1/customer/savings-summary",
    access.require(savingsAccessPolicies.customerRead),
    route(async (request, response) => {
      if (!summaries) throw new Error("Savings-summary handler is unavailable");
      const principal = principalContext(request);
      response.status(200).json(
        await summaries.get({
          tenantId: principal.tenantId,
          customerId: principal.subjectId,
        }),
      );
    }),
  );
  app.post(
    "/internal/v1/interest/accruals",
    access.require(savingsAccessPolicies.operations),
    route(async (request, response) => {
      if (!interest) throw new Error("Interest handler is unavailable");
      const principal = principalContext(request);
      const input = interestAccrualInput.parse(request.body);
      const result = await interest.accrue({
        tenantId: principal.tenantId,
        accountId: input.savings_account_id,
        accrualDate: input.accrual_date,
        currency: input.currency,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response.status(result.replayed ? 200 : 201).json({
        interest_accrual_id: result.accrualId,
        savings_account_id: result.accountId,
        accrual_date: result.accrualDate,
        interest_unrounded_minor: result.interestUnroundedMinor,
        currency: result.currency,
        replayed: result.replayed,
      });
    }),
  );
  app.post(
    "/internal/v1/interest/payments",
    access.require(savingsAccessPolicies.operations),
    route(async (request, response) => {
      if (!interest) throw new Error("Interest handler is unavailable");
      const principal = principalContext(request);
      const input = interestPaymentInput.parse(request.body);
      const result = await interest.pay({
        tenantId: principal.tenantId,
        accountId: input.savings_account_id,
        periodStart: input.period_start,
        periodEnd: input.period_end,
        currency: input.currency,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response.status(result.replayed ? 200 : 201).json({
        interest_payment_id: result.interestPaymentId,
        savings_account_id: result.accountId,
        amount_minor: result.amountMinor,
        rounding_residual_minor: result.roundingResidualMinor,
        ledger_transaction_id: result.ledgerTransactionId,
        currency: result.currency,
        status: result.status,
        replayed: result.replayed,
      });
    }),
  );
  app.post(
    "/v1/recurring-plans",
    access.require(savingsAccessPolicies.customerWrite),
    route(async (request, response) => {
      if (!recurring)
        throw new Error("Recurring-contribution handler is unavailable");
      const principal = principalContext(request);
      const input = recurringPlanInput.parse(request.body);
      const result = await recurring.create({
        tenantId: principal.tenantId,
        customerId: principal.subjectId,
        savingsAccountId: input.savings_account_id,
        ...(input.goal_id ? { goalId: input.goal_id } : {}),
        amountMinor: input.amount_minor,
        currency: input.currency,
        frequency: input.frequency,
        startDate: input.start_date,
        ...(input.end_date ? { endDate: input.end_date } : {}),
        ...(input.max_executions
          ? { maxExecutions: input.max_executions }
          : {}),
        executionTime: input.execution_time,
        timezone: input.timezone,
        consentReference: input.consent_reference,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response.status(result.replayed ? 200 : 201).json({
        recurring_plan_id: result.recurringPlanId,
        savings_account_id: result.savingsAccountId,
        amount_minor: result.amountMinor,
        currency: result.currency,
        frequency: result.frequency,
        next_execution_date: result.nextExecutionDate,
        status: result.status,
        replayed: result.replayed,
      });
    }),
  );
  app.post(
    "/internal/v1/recurring-plans/:id/execute",
    access.require(savingsAccessPolicies.operations),
    route(async (request, response) => {
      if (!recurring)
        throw new Error("Recurring-contribution handler is unavailable");
      principalContext(request);
      const input = recurringExecutionInput.parse(request.body);
      const result = await recurring.execute({
        tenantId: requiredHeader(request, "x-tenant-id"),
        planId: z.string().uuid().parse(request.params.id),
        scheduledDate: input.scheduled_date,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
        workerId: input.worker_id,
      });
      response.status(result.replayed ? 200 : 201).json({
        recurring_execution_id: result.recurringExecutionId,
        recurring_plan_id: result.recurringPlanId,
        scheduled_date: result.scheduledDate,
        amount_minor: result.amountMinor,
        currency: result.currency,
        status: result.status,
        ledger_transaction_id: result.ledgerTransactionId,
        replayed: result.replayed,
      });
    }),
  );
  app.post(
    "/v1/customer/fixed-deposit-quotes",
    access.require(savingsAccessPolicies.customerRead),
    route(async (request, response) => {
      if (!fixedDeposits)
        throw new Error("Fixed-deposit handler is unavailable");
      const principal = principalContext(request);
      const input = fixedDepositQuoteInput.parse(request.body);
      const result = await fixedDeposits.quotePlacement({
        tenantId: principal.tenantId,
        customerId: principal.subjectId,
        productVersionId: input.product_version_id,
        principalMinor: input.principal_minor,
        currency: input.currency,
        tenureDays: input.tenor_days,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response.status(200).json(snakeQuote(result));
    }),
  );
  app.post(
    "/v1/fixed-deposits",
    access.require(savingsAccessPolicies.customerWrite),
    route(async (request, response) => {
      if (!fixedDeposits)
        throw new Error("Fixed-deposit handler is unavailable");
      const principal = principalContext(request);
      const input = fixedDepositInput.parse(request.body);
      const result = await fixedDeposits.create({
        tenantId: principal.tenantId,
        customerId: principal.subjectId,
        productVersionId: input.product_version_id,
        amountMinor: input.amount_minor,
        currency: input.currency,
        tenureDays: input.tenure_days,
        quoteId: input.quote_id,
        quoteHash: input.quote_hash,
        acceptedAt: input.accepted_at,
        acceptanceReference: input.acceptance_reference,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response.status(result.replayed ? 200 : 201).json({
        fixed_deposit_id: result.fixedDepositId,
        principal_minor: result.principalMinor,
        interest_rate: result.interestRate,
        maturity_date: result.maturityDate,
        currency: result.currency,
        status: result.status,
        replayed: result.replayed,
      });
    }),
  );
  app.post(
    "/v1/fixed-deposits/:id/liquidate",
    access.require(savingsAccessPolicies.customerWrite),
    route(async (request, response) => {
      if (!fixedDeposits)
        throw new Error("Fixed-deposit handler is unavailable");
      const principal = principalContext(request);
      const input = fixedDepositLiquidationInput.parse(request.body);
      const result = await fixedDeposits.liquidate({
        tenantId: principal.tenantId,
        customerId: principal.subjectId,
        fixedDepositId: z.string().uuid().parse(request.params.id),
        quoteId: input.quote_id,
        quoteHash: input.quote_hash,
        currency: input.currency,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response
        .status(result.replayed ? 200 : 201)
        .json(snakeSettlement(result));
    }),
  );
  app.post(
    "/v1/fixed-deposits/:id/liquidation-quote",
    access.require(savingsAccessPolicies.customerRead),
    route(async (request, response) => {
      if (!fixedDeposits)
        throw new Error("Fixed-deposit handler is unavailable");
      const principal = principalContext(request);
      const input = fixedDepositSettlementInput.parse(request.body);
      const result = await fixedDeposits.quoteLiquidation({
        tenantId: principal.tenantId,
        customerId: principal.subjectId,
        fixedDepositId: z.string().uuid().parse(request.params.id),
        currency: input.currency,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response.status(200).json(snakeQuote(result));
    }),
  );
  app.get(
    "/v1/customer/fixed-deposits/:id",
    access.require(savingsAccessPolicies.customerRead),
    route(async (request, response) => {
      if (!fixedDeposits)
        throw new Error("Fixed-deposit handler is unavailable");
      const principal = principalContext(request);
      const result = await fixedDeposits.get({
        tenantId: principal.tenantId,
        customerId: principal.subjectId,
        fixedDepositId: z.string().uuid().parse(request.params.id),
      });
      response.status(200).json({
        fixed_deposit_id: result.fixedDepositId,
        product_version_id: result.productVersionId,
        principal_minor: result.principalMinor,
        interest_rate: result.interestRate,
        accrued_interest: result.accruedInterest,
        tenure_days: result.tenureDays,
        start_date: result.startDate,
        maturity_date: result.maturityDate,
        currency: result.currency,
        status: result.status,
        maturity_instruction: result.maturityInstruction,
      });
    }),
  );
  app.put(
    "/v1/fixed-deposits/:id/maturity-instruction",
    access.require(savingsAccessPolicies.customerWrite),
    route(async (request, response) => {
      if (!fixedDeposits)
        throw new Error("Fixed-deposit handler is unavailable");
      const principal = principalContext(request);
      const input = maturityInstructionInput.parse(request.body);
      const instruction = (
        {
          payout: "PAYOUT_ALL",
          renew_principal: "RENEW_PRINCIPAL",
          renew_principal_and_interest: "RENEW_PRINCIPAL_AND_INTEREST",
        } as const
      )[input.instruction];
      const result = await fixedDeposits.setMaturityInstruction({
        tenantId: principal.tenantId,
        customerId: principal.subjectId,
        fixedDepositId: z.string().uuid().parse(request.params.id),
        instruction,
        ...(input.renewal_tenure_days
          ? { renewalTenureDays: input.renewal_tenure_days }
          : {}),
        currency: input.currency,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response.status(200).json({
        instruction_id: result.instructionId,
        instruction: input.instruction,
        replayed: result.replayed,
      });
    }),
  );
  app.post(
    "/internal/v1/fixed-deposits/:id/mature",
    access.require(savingsAccessPolicies.operations),
    route(async (request, response) => {
      if (!fixedDeposits)
        throw new Error("Fixed-deposit handler is unavailable");
      const principal = principalContext(request);
      const input = fixedDepositSettlementInput.parse(request.body);
      const result = await fixedDeposits.mature({
        tenantId: principal.tenantId,
        fixedDepositId: z.string().uuid().parse(request.params.id),
        currency: input.currency,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response
        .status(result.replayed ? 200 : 201)
        .json(snakeSettlement(result));
    }),
  );
  app.post(
    "/v1/savings-products",
    access.require(savingsAccessPolicies.productsManage),
    route(async (request, response) => {
      const principal = principalContext(request);
      const input = productInput.parse(request.body);
      response.status(201).json(
        await products.createProduct({
          tenantId: principal.tenantId,
          code: input.code,
          name: input.name,
          productType: input.product_type,
          ...(input.description ? { description: input.description } : {}),
          idempotencyKey: requiredHeader(request, "idempotency-key"),
        }),
      );
    }),
  );
  app.post(
    "/v1/savings-goals",
    access.require(savingsAccessPolicies.customerWrite),
    route(async (request, response) => {
      if (!targets) throw new Error("Target savings handler is unavailable");
      const principal = principalContext(request);
      const input = goalInput.parse(request.body);
      if (input.customer_id !== principal.subjectId)
        throw new Error("Customer identity mismatch");
      const result = await targets.createGoal({
        tenantId: principal.tenantId,
        customerId: principal.subjectId,
        accountId: input.savings_account_id,
        name: input.name,
        targetAmountMinor: input.target_amount_minor,
        currency: input.currency,
        targetDate: input.target_date,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response.status(result.replayed ? 200 : 201).json({
        id: result.id,
        savings_account_id: result.savingsAccountId,
        customer_id: principal.subjectId,
        target_amount_minor: result.targetAmountMinor,
        currency: result.currency,
        target_date: result.targetDate,
        status: result.status,
        replayed: result.replayed,
      });
    }),
  );
  app.post(
    "/v1/savings-goals/:id/partial-withdrawal",
    access.require(savingsAccessPolicies.customerWrite),
    route(async (request, response) => {
      if (!targets) throw new Error("Target savings handler is unavailable");
      const principal = principalContext(request);
      const input = goalPartialInput.parse(request.body);
      const result = await targets.partialWithdraw({
        tenantId: principal.tenantId,
        customerId: principal.subjectId,
        goalId: z.string().uuid().parse(request.params.id),
        amountMinor: input.amount_minor,
        currency: input.currency,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response
        .status(result.replayed ? 200 : 201)
        .json(goalWithdrawalResult(result));
    }),
  );
  app.post(
    "/v1/savings-goals/:id/break",
    access.require(savingsAccessPolicies.customerWrite),
    route(async (request, response) => {
      if (!targets) throw new Error("Target savings handler is unavailable");
      const principal = principalContext(request);
      const input = goalBreakInput.parse(request.body);
      const result = await targets.breakGoal({
        tenantId: principal.tenantId,
        customerId: principal.subjectId,
        goalId: z.string().uuid().parse(request.params.id),
        currency: input.currency,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response
        .status(result.replayed ? 200 : 201)
        .json(goalWithdrawalResult(result));
    }),
  );
  app.post(
    "/v1/savings-products/:id/versions",
    access.require(savingsAccessPolicies.productsManage),
    route(async (request, response) => {
      const principal = principalContext(request);
      const input = versionInput.parse(request.body);
      const { effective_from: effectiveFrom, ...terms } = input;
      response.status(201).json(
        await products.createVersion({
          tenantId: principal.tenantId,
          productId: z.string().uuid().parse(request.params.id),
          terms: camel(terms) as unknown as Parameters<
            SavingsProductService["createVersion"]
          >[0]["terms"],
          effectiveFrom,
          createdBy: principal.subjectId,
          idempotencyKey: requiredHeader(request, "idempotency-key"),
        }),
      );
    }),
  );
  app.post(
    "/v1/savings-products/:id/publish",
    access.require(savingsAccessPolicies.productsPublish),
    route(async (request, response) => {
      const principal = principalContext(request);
      const input = publishInput.parse(request.body);
      if (principal.subjectId !== input.publisher_id)
        throw new Error("Publisher identity mismatch");
      response.status(200).json(
        await products.publish({
          tenantId: principal.tenantId,
          productId: z.string().uuid().parse(request.params.id),
          versionId: input.version_id,
          approvalId: input.approval_id,
          publisherId: input.publisher_id,
          correlationId: input.correlation_id,
          idempotencyKey: requiredHeader(request, "idempotency-key"),
        }),
      );
    }),
  );
  app.post(
    "/v1/savings-accounts",
    access.require(savingsAccessPolicies.customerWrite),
    route(async (request, response) => {
      if (!ordinary) throw new Error("Ordinary savings handler is unavailable");
      const principal = principalContext(request);
      const input = accountInput.parse(request.body);
      if (input.customer_id !== principal.subjectId)
        throw new Error("Customer identity mismatch");
      const result = await ordinary.openAccount({
        tenantId: principal.tenantId,
        customerId: principal.subjectId,
        productVersionId: input.product_version_id,
        currency: input.currency,
        acceptedAt: input.accepted_at,
        acceptanceReference: input.acceptance_reference,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response.status(result.replayed ? 200 : 201).json({
        id: result.id,
        customer_id: principal.subjectId,
        product_version_id: result.productVersionId,
        account_number: result.accountNumber,
        currency: result.currency,
        status: result.status,
        replayed: result.replayed,
      });
    }),
  );
  app.post(
    "/v1/savings-accounts/:id/contributions",
    access.require(savingsAccessPolicies.customerWrite),
    route(async (request, response) => {
      if (!ordinary) throw new Error("Ordinary savings handler is unavailable");
      const principal = principalContext(request);
      const input = contributionInput.parse(request.body);
      const result = await ordinary.contribute({
        tenantId: principal.tenantId,
        customerId: principal.subjectId,
        accountId: z.string().uuid().parse(request.params.id),
        ...(input.goal_id ? { goalId: input.goal_id } : {}),
        amountMinor: input.amount_minor,
        currency: input.currency,
        correlationId: input.correlation_id,
        idempotencyKey: requiredHeader(request, "idempotency-key"),
      });
      response.status(result.replayed ? 200 : 201).json({
        contribution_id: result.contributionId,
        savings_account_id: result.savingsAccountId,
        ledger_transaction_id: result.ledgerTransactionId,
        amount_minor: result.amountMinor,
        currency: result.currency,
        status: result.status,
        replayed: result.replayed,
      });
    }),
  );
  app.use(
    (
      error: unknown,
      _request: Request,
      response: Response,
      _next: NextFunction,
    ) => {
      void _next;
      if (error instanceof z.ZodError)
        return response
          .status(400)
          .json({ code: "INVALID_REQUEST", details: error.flatten() });
      if (error instanceof ParcAuthError)
        return response.status(error.status).json({ code: error.code });
      // Services raise plain Errors for intentional domain rejections; anything
      // else (database, network, programming errors) is unexpected.
      if (!(error instanceof Error) || error.constructor !== Error) {
        console.error(error);
        return response.status(500).json({ code: "INTERNAL_ERROR" });
      }
      if (/(identity|context) mismatch/.test(error.message))
        return response.status(403).json({ code: error.message });
      return response
        .status(
          error.message.includes("not found")
            ? 404
            : error.message.includes("Idempotency") ||
                error.message.includes("conflict")
              ? 409
              : 422,
        )
        .json({ code: error.message });
    },
  );
  return app;
}
function snakeSettlement(result: Record<string, unknown>) {
  return {
    fixed_deposit_id: result.fixed_deposit_id,
    principal_minor: result.principal_minor,
    interest_minor: result.interest_minor,
    penalty_minor: result.penalty_minor,
    payout_minor: result.payout_minor,
    ledger_transaction_id: result.ledgerTransactionId,
    currency: result.currency,
    status: result.status,
    renewed_fixed_deposit_id: result.renewedFixedDepositId,
    renewed_principal_minor: result.renewedPrincipalMinor,
    renewed_maturity_date: result.renewedMaturityDate,
    replayed: result.replayed,
  };
}
function snakeQuote(result: Record<string, unknown>) {
  return {
    quote_id: result.quoteId,
    quote_hash: result.quoteHash,
    principal_minor: result.principalMinor,
    interest_rate: result.interestRate,
    tenure_days: result.tenureDays,
    expected_interest_minor: result.expectedInterestMinor,
    penalty_minor: result.penaltyMinor,
    payout_minor: result.payoutMinor,
    currency: result.currency,
    expires_at: result.expiresAt,
    replayed: result.replayed,
  };
}
/**
 * The tenant and acting user from the validated token. The access policy has
 * already checked the token kind, user type, acting service and scope, and the
 * middleware has checked that X-Tenant-Id matches the token.
 */
function principalContext(request: Request): {
  tenantId: string;
  subjectId: string;
} {
  const principal = principalOf(request);
  const tenantId = z
    .string()
    .uuid()
    .parse(requiredHeader(request, "x-tenant-id"));
  if (principal.tenantId !== tenantId)
    throw new Error("Tenant context mismatch");
  return { tenantId, subjectId: principal.subject?.id ?? principal.client };
}
function requiredHeader(request: Request, name: string): string {
  const value = request.header(name);
  if (!value) throw new Error(`${name} is required`);
  return value;
}
function camel(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [
      key.replace(/_([a-z])/g, (_match, letter: string) =>
        letter.toUpperCase(),
      ),
      item,
    ]),
  );
}
function goalWithdrawalResult(
  result: Awaited<ReturnType<TargetSavingsService["partialWithdraw"]>>,
) {
  return {
    withdrawal_id: result.withdrawalId,
    goal_id: result.goalId,
    principal_minor: result.principalMinor,
    forfeited_interest_minor: result.forfeitedInterestMinor,
    ledger_transaction_id: result.ledgerTransactionId,
    currency: result.currency,
    goal_status: result.goalStatus,
    status: result.status,
    replayed: result.replayed,
  };
}
function route(
  handler: (request: Request, response: Response) => Promise<void>,
) {
  return (request: Request, response: Response, next: NextFunction) => {
    void handler(request, response).catch(next);
  };
}
