import type { Knex } from "knex";

export async function up(knex: Knex): Promise<void> {
  if (
    await knex.schema.hasColumn(
      "savings_interest_accruals",
      "calculation_snapshot",
    )
  )
    return;
  await knex.raw(`
    ALTER TABLE savings_interest_accrual_batches
      ALTER COLUMN total_interest TYPE numeric(30,12),
      ADD COLUMN idempotency_key varchar(255), ADD COLUMN request_hash char(64), ADD COLUMN correlation_id uuid,
      ADD COLUMN attempt_count integer NOT NULL DEFAULT 0, ADD COLUMN locked_at timestamptz, ADD COLUMN locked_by text,
      ADD COLUMN lease_expires_at timestamptz, ADD COLUMN next_retry_at timestamptz,
      ADD CONSTRAINT interest_accrual_batch_hash CHECK (request_hash IS NULL OR request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT interest_accrual_batch_attempts CHECK (attempt_count>=0),
      ADD CONSTRAINT interest_accrual_batch_lease CHECK ((locked_at IS NULL)=(locked_by IS NULL) AND (locked_at IS NULL)=(lease_expires_at IS NULL));
    CREATE UNIQUE INDEX uq_interest_accrual_batch_idempotency ON savings_interest_accrual_batches(tenant_id,idempotency_key) WHERE idempotency_key IS NOT NULL;

    ALTER TABLE savings_interest_accruals DROP CONSTRAINT chk_interest_accrual_balance;
    ALTER TABLE savings_interest_accruals DROP CONSTRAINT chk_interest_accrual_rate;
    ALTER TABLE savings_interest_accruals DROP CONSTRAINT savings_interest_accruals_calculation_basis_amount_check;
    ALTER TABLE savings_interest_accruals
      ALTER COLUMN opening_balance TYPE bigint USING round(opening_balance*100)::bigint,
      ALTER COLUMN calculation_basis_amount TYPE bigint USING round(calculation_basis_amount*100)::bigint,
      ALTER COLUMN applicable_rate TYPE numeric(18,10),
      ALTER COLUMN interest_amount TYPE numeric(30,12),
      ADD COLUMN request_hash char(64), ADD COLUMN calculation_snapshot jsonb,
      ADD CONSTRAINT interest_accrual_opening_minor CHECK (opening_balance>=0),
      ADD CONSTRAINT interest_accrual_basis_minor CHECK (calculation_basis_amount>=0),
      ADD CONSTRAINT interest_accrual_rate CHECK (applicable_rate>=0),
      ADD CONSTRAINT interest_accrual_request_hash CHECK (request_hash IS NOT NULL AND request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT interest_accrual_snapshot CHECK (calculation_snapshot IS NOT NULL AND jsonb_typeof(calculation_snapshot)='object');
    ALTER TABLE savings_interest_accruals DROP CONSTRAINT uq_savings_interest_accrual;
    ALTER TABLE savings_interest_accruals ADD CONSTRAINT uq_savings_interest_accrual UNIQUE(tenant_id,savings_account_id,accrual_date);

    ALTER TABLE savings_interest_payment_batches
      ADD COLUMN idempotency_key varchar(255), ADD COLUMN request_hash char(64), ADD COLUMN correlation_id uuid,
      ADD COLUMN attempt_count integer NOT NULL DEFAULT 0, ADD COLUMN locked_at timestamptz, ADD COLUMN locked_by text,
      ADD COLUMN lease_expires_at timestamptz, ADD COLUMN next_retry_at timestamptz,
      ADD COLUMN payments_processed integer NOT NULL DEFAULT 0, ADD COLUMN total_paid_minor bigint NOT NULL DEFAULT 0,
      ADD CONSTRAINT interest_payment_batch_hash CHECK (request_hash IS NULL OR request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT interest_payment_batch_counts CHECK (attempt_count>=0 AND payments_processed>=0 AND total_paid_minor>=0),
      ADD CONSTRAINT interest_payment_batch_lease CHECK ((locked_at IS NULL)=(locked_by IS NULL) AND (locked_at IS NULL)=(lease_expires_at IS NULL));
    CREATE UNIQUE INDEX uq_interest_payment_batch_idempotency ON savings_interest_payment_batches(tenant_id,idempotency_key) WHERE idempotency_key IS NOT NULL;

    ALTER TABLE savings_interest_payments DROP COLUMN net_amount;
    ALTER TABLE savings_interest_payments
      ALTER COLUMN amount TYPE bigint USING round(amount*100)::bigint,
      ALTER COLUMN tax_amount TYPE bigint USING round(tax_amount*100)::bigint,
      ALTER COLUMN rounding_adjustment TYPE bigint USING round(rounding_adjustment*100)::bigint,
      ADD COLUMN net_amount bigint GENERATED ALWAYS AS (amount-tax_amount) STORED,
      ADD COLUMN request_hash char(64), ADD COLUMN calculation_snapshot jsonb,
      ADD COLUMN ledger_journal_id uuid, ADD COLUMN ledger_request_hash char(64), ADD COLUMN ledger_posted_at timestamptz,
      ADD COLUMN interest_expense_account_id uuid,
      ADD CONSTRAINT interest_payment_hash CHECK (request_hash IS NOT NULL AND request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT interest_payment_ledger_hash CHECK (ledger_request_hash IS NULL OR ledger_request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT interest_payment_snapshot CHECK (calculation_snapshot IS NOT NULL AND jsonb_typeof(calculation_snapshot)='object'),
      ADD CONSTRAINT interest_payment_success_evidence CHECK (status<>'SUCCESSFUL' OR (ledger_transaction_id IS NOT NULL AND ledger_journal_id IS NOT NULL AND ledger_request_hash IS NOT NULL AND ledger_posted_at IS NOT NULL AND interest_expense_account_id IS NOT NULL AND paid_at IS NOT NULL));
    ALTER TABLE savings_interest_payments DROP CONSTRAINT savings_interest_payments_rounding_adjustment_check;

    ALTER TABLE savings_interest_payment_accruals RENAME COLUMN allocated_amount TO allocated_unrounded;
    ALTER TABLE savings_interest_payment_accruals
      ALTER COLUMN allocated_unrounded TYPE numeric(30,12),
      ADD COLUMN allocated_minor bigint NOT NULL DEFAULT 0,
      ADD CONSTRAINT interest_allocation_minor CHECK (allocated_minor>=0);

    ALTER TABLE savings_interest_accrual_corrections
      ALTER COLUMN signed_amount TYPE numeric(30,12),
      ADD COLUMN approval_id uuid, ADD COLUMN approval_authority_level integer,
      ADD COLUMN ledger_journal_id uuid, ADD COLUMN ledger_request_hash char(64), ADD COLUMN ledger_posted_at timestamptz,
      ADD CONSTRAINT interest_correction_approval CHECK (approval_id IS NOT NULL AND created_by<>approved_by),
      ADD CONSTRAINT interest_correction_ledger CHECK (ledger_request_hash IS NOT NULL AND ledger_request_hash ~ '^[a-f0-9]{64}$' AND ledger_journal_id IS NOT NULL AND ledger_posted_at IS NOT NULL);

    CREATE OR REPLACE FUNCTION savings_check_interest_total() RETURNS trigger LANGUAGE plpgsql AS $fn$
    DECLARE total bigint;
    BEGIN
      IF NEW.status='SUCCESSFUL' AND NEW.settlement_basis='ACCRUED' THEN
        SELECT sum(allocated_minor) INTO total FROM savings_interest_payment_accruals WHERE tenant_id=NEW.tenant_id AND interest_payment_id=NEW.id;
        IF total IS NULL OR total+NEW.rounding_adjustment<>NEW.amount THEN RAISE EXCEPTION 'Allocated minor units plus residual must equal posted interest'; END IF;
      END IF;
      RETURN NEW;
    END $fn$;
    CREATE OR REPLACE FUNCTION savings_validate_allocation() RETURNS trigger LANGUAGE plpgsql AS $fn$
    DECLARE p savings_interest_payments%ROWTYPE; a savings_interest_accruals%ROWTYPE;
    BEGIN
      SELECT * INTO p FROM savings_interest_payments WHERE tenant_id=NEW.tenant_id AND id=NEW.interest_payment_id FOR UPDATE;
      SELECT * INTO a FROM savings_interest_accruals WHERE tenant_id=NEW.tenant_id AND id=NEW.interest_accrual_id FOR UPDATE;
      IF p.id IS NULL OR a.id IS NULL OR p.settlement_basis<>'ACCRUED' OR p.status IN ('SUCCESSFUL','REVERSED','CANCELLED') OR a.posted
        OR a.savings_account_id<>p.savings_account_id OR a.currency<>p.currency OR a.accrual_date<p.payment_period_start OR a.accrual_date>p.payment_period_end
        OR NEW.allocated_unrounded<>a.interest_amount OR NEW.allocated_minor<>(CASE WHEN a.interest_amount-floor(a.interest_amount)=0.5 THEN floor(a.interest_amount)+mod(floor(a.interest_amount),2) ELSE round(a.interest_amount) END)::bigint
      THEN RAISE EXCEPTION 'Interest allocation does not match eligible accrual'; END IF;
      RETURN NEW;
    END $fn$;
  `);
}

export function down(): Promise<never> {
  return Promise.reject(new Error("SV-06 interest migration is forward-only"));
}
