import type { Knex } from "knex";

export async function up(knex: Knex): Promise<void> {
  if (
    await knex.schema.hasColumn(
      "savings_recurring_plans",
      "creation_request_hash",
    )
  )
    return;
  await knex.raw(`
    ALTER TABLE savings_recurring_plans DROP CONSTRAINT chk_recurring_amount;
    ALTER TABLE savings_recurring_plans
      ALTER COLUMN amount TYPE bigint USING round(amount*100)::bigint,
      ADD COLUMN status text NOT NULL DEFAULT 'ACTIVE',
      ADD COLUMN funding_source text NOT NULL DEFAULT 'WALLET',
      ADD COLUMN creation_idempotency_key varchar(255),
      ADD COLUMN creation_request_hash char(64),
      ADD COLUMN correlation_id uuid,
      ADD COLUMN consent_reference varchar(255),
      ADD COLUMN schedule_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
      ADD COLUMN aggregate_version bigint NOT NULL DEFAULT 1,
      ADD COLUMN completed_at timestamptz,
      ADD COLUMN cancelled_at timestamptz,
      ADD CONSTRAINT recurring_plan_amount_minor CHECK (amount>0),
      ADD CONSTRAINT recurring_plan_status CHECK (status IN ('ACTIVE','PAUSED','COMPLETED','CANCELLED','EXHAUSTED')),
      ADD CONSTRAINT recurring_plan_wallet_only CHECK (funding_source='WALLET' AND source_account_id IS NOT NULL),
      ADD CONSTRAINT recurring_plan_creation_hash CHECK (creation_request_hash IS NULL OR creation_request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT recurring_plan_creation_evidence CHECK (creation_idempotency_key IS NOT NULL AND creation_request_hash IS NOT NULL AND correlation_id IS NOT NULL AND consent_reference IS NOT NULL),
      ADD CONSTRAINT recurring_plan_snapshot CHECK (jsonb_typeof(schedule_snapshot)='object'),
      ADD CONSTRAINT recurring_plan_aggregate_version CHECK (aggregate_version>0),
      ADD CONSTRAINT recurring_plan_terminal_time CHECK ((status NOT IN ('COMPLETED','EXHAUSTED') OR completed_at IS NOT NULL) AND (status<>'CANCELLED' OR cancelled_at IS NOT NULL));
    CREATE UNIQUE INDEX uq_recurring_plan_creation_idempotency ON savings_recurring_plans(tenant_id,creation_idempotency_key);
    CREATE INDEX idx_recurring_plan_claim ON savings_recurring_plans(tenant_id,next_execution_date,id) WHERE status='ACTIVE' AND is_active;

    ALTER TABLE savings_recurring_executions DROP CONSTRAINT chk_recurring_execution_amount;
    ALTER TABLE savings_recurring_executions DROP CONSTRAINT uq_recurring_execution;
    ALTER TABLE savings_recurring_executions
      ALTER COLUMN amount TYPE bigint USING round(amount*100)::bigint,
      ADD COLUMN request_hash char(64),
      ADD COLUMN ledger_journal_id uuid,
      ADD COLUMN ledger_request_hash char(64),
      ADD COLUMN ledger_posted_at timestamptz,
      ADD COLUMN lease_expires_at timestamptz,
      ADD COLUMN retry_classification text,
      ADD COLUMN terminal_at timestamptz,
      ADD CONSTRAINT recurring_execution_amount_minor CHECK (amount>0),
      ADD CONSTRAINT recurring_execution_hash CHECK (request_hash IS NOT NULL AND request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT recurring_execution_ledger_hash CHECK (ledger_request_hash IS NULL OR ledger_request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT recurring_execution_retry_classification CHECK (retry_classification IS NULL OR retry_classification IN ('RETRYABLE','TERMINAL','INSUFFICIENT_FUNDS')),
      ADD CONSTRAINT recurring_execution_lease CHECK ((locked_at IS NULL)=(locked_by IS NULL) AND (locked_at IS NULL)=(lease_expires_at IS NULL)),
      ADD CONSTRAINT recurring_execution_success_evidence CHECK (status<>'SUCCESSFUL' OR (deposit_id IS NOT NULL AND ledger_transaction_id IS NOT NULL AND ledger_journal_id IS NOT NULL AND ledger_request_hash IS NOT NULL AND ledger_posted_at IS NOT NULL AND completed_at IS NOT NULL));
    ALTER TABLE savings_recurring_executions ADD CONSTRAINT uq_recurring_execution UNIQUE(tenant_id,recurring_plan_id,execution_number);
    CREATE INDEX idx_recurring_execution_retry ON savings_recurring_executions(tenant_id,next_retry_at,id) WHERE status IN ('PENDING','FAILED');

    CREATE OR REPLACE FUNCTION savings_validate_recurring_plan() RETURNS trigger LANGUAGE plpgsql AS $fn$
    DECLARE a savings_accounts%ROWTYPE; g savings_goals%ROWTYPE;
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Recurring plans cannot be deleted'; END IF;
      IF TG_OP='INSERT' OR (NEW.status='ACTIVE' AND OLD.status<>'ACTIVE') THEN
        SELECT * INTO a FROM savings_accounts WHERE tenant_id=NEW.tenant_id AND id=NEW.savings_account_id;
        IF NOT FOUND OR a.customer_id<>NEW.customer_id OR a.currency<>NEW.currency OR a.status<>'ACTIVE' OR a.product_type NOT IN ('ORDINARY','TARGET')
        THEN RAISE EXCEPTION 'Recurring plan requires an active customer-owned savings account'; END IF;
        IF (a.product_type='TARGET')<>(NEW.goal_id IS NOT NULL) THEN RAISE EXCEPTION 'Target recurring plan requires goal'; END IF;
        IF NEW.goal_id IS NOT NULL THEN
          SELECT * INTO g FROM savings_goals WHERE tenant_id=NEW.tenant_id AND id=NEW.goal_id;
          IF NOT FOUND OR g.savings_account_id<>NEW.savings_account_id OR g.customer_id<>NEW.customer_id OR g.status<>'ACTIVE'
          THEN RAISE EXCEPTION 'Recurring goal must be active and match account/customer'; END IF;
        END IF;
      END IF;
      IF TG_OP='UPDATE' THEN
        IF (NEW.tenant_id,NEW.id,NEW.savings_account_id,NEW.customer_id,NEW.goal_id,NEW.amount,NEW.currency,NEW.frequency,NEW.start_date,NEW.end_date,NEW.max_executions,NEW.source_account_id,NEW.funding_source,NEW.timezone_name,NEW.execution_time,NEW.retry_limit,NEW.creation_idempotency_key,NEW.creation_request_hash,NEW.consent_reference,NEW.schedule_snapshot)
          IS DISTINCT FROM (OLD.tenant_id,OLD.id,OLD.savings_account_id,OLD.customer_id,OLD.goal_id,OLD.amount,OLD.currency,OLD.frequency,OLD.start_date,OLD.end_date,OLD.max_executions,OLD.source_account_id,OLD.funding_source,OLD.timezone_name,OLD.execution_time,OLD.retry_limit,OLD.creation_idempotency_key,OLD.creation_request_hash,OLD.consent_reference,OLD.schedule_snapshot)
        THEN RAISE EXCEPTION 'Recurring plan configuration is immutable'; END IF;
        IF OLD.status IN ('COMPLETED','CANCELLED','EXHAUSTED') AND NEW.status<>OLD.status THEN RAISE EXCEPTION 'Terminal recurring plan is immutable'; END IF;
        IF NEW.status<>OLD.status AND NOT ((OLD.status='ACTIVE' AND NEW.status IN ('PAUSED','COMPLETED','CANCELLED','EXHAUSTED')) OR (OLD.status='PAUSED' AND NEW.status IN ('ACTIVE','CANCELLED'))) THEN RAISE EXCEPTION 'Invalid recurring plan transition'; END IF;
        NEW.aggregate_version=OLD.aggregate_version+1;
      END IF;
      RETURN NEW;
    END $fn$;
    CREATE TRIGGER validate_recurring_plan BEFORE INSERT OR UPDATE OR DELETE ON savings_recurring_plans FOR EACH ROW EXECUTE FUNCTION savings_validate_recurring_plan();

    CREATE OR REPLACE FUNCTION savings_validate_recurring_execution() RETURNS trigger LANGUAGE plpgsql AS $fn$
    DECLARE p savings_recurring_plans%ROWTYPE; d savings_deposits%ROWTYPE;
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Recurring executions cannot be deleted'; END IF;
      SELECT * INTO p FROM savings_recurring_plans WHERE tenant_id=NEW.tenant_id AND id=NEW.recurring_plan_id;
      IF NOT FOUND OR NEW.amount<>p.amount THEN RAISE EXCEPTION 'Execution must match recurring plan'; END IF;
      IF NEW.deposit_id IS NOT NULL THEN
        SELECT * INTO d FROM savings_deposits WHERE tenant_id=NEW.tenant_id AND id=NEW.deposit_id;
        IF NOT FOUND OR d.savings_account_id<>p.savings_account_id OR d.customer_id<>p.customer_id OR d.amount<>NEW.amount OR d.currency<>p.currency OR d.ledger_transaction_id IS DISTINCT FROM NEW.ledger_transaction_id
        THEN RAISE EXCEPTION 'Recurring execution deposit evidence mismatch'; END IF;
      END IF;
      RETURN NEW;
    END $fn$;
    CREATE TRIGGER validate_recurring_execution BEFORE INSERT OR UPDATE ON savings_recurring_executions FOR EACH ROW EXECUTE FUNCTION savings_validate_recurring_execution();
  `);
}

export function down(): Promise<never> {
  return Promise.reject(
    new Error("SV-05 recurring-contribution migration is forward-only"),
  );
}
