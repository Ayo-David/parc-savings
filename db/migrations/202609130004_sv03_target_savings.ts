import type { Knex } from "knex";

export async function up(knex: Knex): Promise<void> {
  if (await knex.schema.hasColumn("savings_goals", "creation_request_hash"))
    return;
  await knex.raw(`
    DROP TRIGGER protect_final ON savings_goal_contributions;
    DROP TRIGGER protect_final ON savings_goal_withdrawals;
    DROP TRIGGER protect_final ON savings_withdrawals;

    ALTER TABLE savings_goals DROP CONSTRAINT chk_savings_goal_current;
    ALTER TABLE savings_goals DROP CONSTRAINT chk_savings_goal_target;
    ALTER TABLE savings_goals
      ALTER COLUMN target_amount TYPE bigint USING round(target_amount*100)::bigint,
      ALTER COLUMN current_amount TYPE bigint USING round(current_amount*100)::bigint,
      ADD COLUMN creation_idempotency_key varchar(255),
      ADD COLUMN creation_request_hash char(64),
      ADD COLUMN product_terms_hash char(64),
      ADD COLUMN partial_withdrawal_limit_rate numeric(18,10) NOT NULL DEFAULT 50,
      ADD COLUMN partial_withdrawal_limit_count integer NOT NULL DEFAULT 1,
      ADD COLUMN partial_withdrawal_count integer NOT NULL DEFAULT 0,
      ADD COLUMN withdrawn_interest_forfeiture boolean NOT NULL DEFAULT true,
      ADD COLUMN break_forfeits_all_interest boolean NOT NULL DEFAULT true,
      ADD COLUMN accrued_interest numeric(30,12) NOT NULL DEFAULT 0,
      ADD COLUMN broken_at timestamptz,
      ADD COLUMN completed_at timestamptz,
      ADD COLUMN lifecycle_evidence jsonb,
      ADD CONSTRAINT chk_savings_goal_current CHECK (current_amount>=0),
      ADD CONSTRAINT chk_savings_goal_target CHECK (target_amount>0),
      ADD CONSTRAINT savings_goal_creation_hash CHECK (creation_request_hash IS NULL OR creation_request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT savings_goal_terms_hash CHECK (product_terms_hash IS NULL OR product_terms_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT savings_goal_partial_policy CHECK (partial_withdrawal_limit_rate=50 AND partial_withdrawal_limit_count=1 AND partial_withdrawal_count BETWEEN 0 AND partial_withdrawal_limit_count),
      ADD CONSTRAINT savings_goal_interest_nonnegative CHECK (accrued_interest>=0),
      ADD CONSTRAINT savings_goal_lifecycle_evidence CHECK ((status<>'CANCELLED' OR (broken_at IS NOT NULL AND lifecycle_evidence IS NOT NULL)) AND (status<>'COMPLETED' OR completed_at IS NOT NULL));
    CREATE UNIQUE INDEX uq_savings_goal_creation_idempotency ON savings_goals(tenant_id,creation_idempotency_key) WHERE creation_idempotency_key IS NOT NULL;

    ALTER TABLE savings_goal_contributions DROP CONSTRAINT chk_goal_contribution_amount;
    ALTER TABLE savings_goal_contributions
      ALTER COLUMN amount TYPE bigint USING round(amount*100)::bigint,
      ADD CONSTRAINT chk_goal_contribution_amount CHECK (amount>0);

    ALTER TABLE savings_goal_withdrawals DROP CONSTRAINT chk_goal_withdrawal_amount;
    ALTER TABLE savings_goal_withdrawals
      ALTER COLUMN amount TYPE bigint USING round(amount*100)::bigint,
      ADD COLUMN withdrawal_kind text NOT NULL DEFAULT 'PARTIAL',
      ADD COLUMN forfeited_interest_minor bigint NOT NULL DEFAULT 0,
      ADD COLUMN idempotency_key varchar(255),
      ADD COLUMN request_hash char(64),
      ADD COLUMN ledger_journal_id uuid,
      ADD COLUMN ledger_request_hash char(64),
      ADD COLUMN ledger_posted_at timestamptz,
      ADD CONSTRAINT chk_goal_withdrawal_amount CHECK (amount>0),
      ADD CONSTRAINT savings_goal_withdrawal_kind CHECK (withdrawal_kind IN ('PARTIAL','BREAK')),
      ADD CONSTRAINT savings_goal_withdrawal_forfeiture CHECK (forfeited_interest_minor>=0),
      ADD CONSTRAINT savings_goal_withdrawal_hash CHECK (request_hash IS NULL OR request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT savings_goal_withdrawal_ledger_hash CHECK (ledger_request_hash IS NULL OR ledger_request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT savings_goal_withdrawal_success CHECK (status<>'SUCCESSFUL' OR (ledger_transaction_id IS NOT NULL AND ledger_journal_id IS NOT NULL AND ledger_request_hash IS NOT NULL AND ledger_posted_at IS NOT NULL AND processed_at IS NOT NULL));
    CREATE UNIQUE INDEX uq_savings_goal_withdrawal_idempotency ON savings_goal_withdrawals(tenant_id,idempotency_key) WHERE idempotency_key IS NOT NULL;
    CREATE UNIQUE INDEX uq_savings_goal_one_partial ON savings_goal_withdrawals(tenant_id,goal_id) WHERE withdrawal_kind='PARTIAL' AND status NOT IN ('FAILED','CANCELLED','REVERSED');
    CREATE UNIQUE INDEX uq_savings_goal_one_break ON savings_goal_withdrawals(tenant_id,goal_id) WHERE withdrawal_kind='BREAK' AND status NOT IN ('FAILED','CANCELLED','REVERSED');

    ALTER TABLE savings_withdrawals DROP CONSTRAINT chk_savings_withdrawal_amount;
    ALTER TABLE savings_withdrawals DROP CONSTRAINT chk_savings_withdrawal_fee;
    ALTER TABLE savings_withdrawals
      ALTER COLUMN amount TYPE bigint USING round(amount*100)::bigint,
      ALTER COLUMN fee_amount TYPE bigint USING round(fee_amount*100)::bigint,
      ADD COLUMN request_hash char(64),
      ADD COLUMN ledger_journal_id uuid,
      ADD COLUMN ledger_request_hash char(64),
      ADD COLUMN ledger_posted_at timestamptz,
      ADD CONSTRAINT chk_savings_withdrawal_amount CHECK (amount>0),
      ADD CONSTRAINT chk_savings_withdrawal_fee CHECK (fee_amount>=0),
      ADD CONSTRAINT savings_withdrawal_request_hash CHECK (request_hash IS NULL OR request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT savings_withdrawal_ledger_hash CHECK (ledger_request_hash IS NULL OR ledger_request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT savings_withdrawal_success_evidence CHECK (status<>'SUCCESSFUL' OR (ledger_transaction_id IS NOT NULL AND ledger_journal_id IS NOT NULL AND ledger_request_hash IS NOT NULL AND ledger_posted_at IS NOT NULL AND processed_at IS NOT NULL));

    CREATE OR REPLACE FUNCTION savings_protect_goal_final() RETURNS trigger LANGUAGE plpgsql AS $fn$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Final goal operations cannot be deleted'; END IF;
      IF OLD.status='SUCCESSFUL' THEN RAISE EXCEPTION 'Successful goal operations are immutable'; END IF;
      RETURN NEW;
    END $fn$;
    CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON savings_goal_contributions FOR EACH ROW EXECUTE FUNCTION savings_protect_goal_final();
    CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON savings_goal_withdrawals FOR EACH ROW EXECUTE FUNCTION savings_protect_goal_final();

    CREATE OR REPLACE FUNCTION savings_protect_withdrawal() RETURNS trigger LANGUAGE plpgsql AS $fn$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Savings withdrawals cannot be deleted'; END IF;
      IF OLD.status='SUCCESSFUL' THEN RAISE EXCEPTION 'Successful savings withdrawals are immutable'; END IF;
      IF (NEW.tenant_id,NEW.id,NEW.savings_account_id,NEW.customer_id,NEW.amount,NEW.currency,NEW.operation_id,NEW.idempotency_key,NEW.request_hash)
         IS DISTINCT FROM (OLD.tenant_id,OLD.id,OLD.savings_account_id,OLD.customer_id,OLD.amount,OLD.currency,OLD.operation_id,OLD.idempotency_key,OLD.request_hash)
      THEN RAISE EXCEPTION 'Savings withdrawal command identity is immutable'; END IF;
      RETURN NEW;
    END $fn$;
    CREATE TRIGGER protect_final BEFORE DELETE OR UPDATE ON savings_withdrawals FOR EACH ROW EXECUTE FUNCTION savings_protect_withdrawal();

    CREATE OR REPLACE FUNCTION savings_protect_goal() RETURNS trigger LANGUAGE plpgsql AS $fn$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Savings goals cannot be deleted'; END IF;
      IF (NEW.tenant_id,NEW.id,NEW.savings_account_id,NEW.customer_id,NEW.target_amount,NEW.currency,NEW.target_date,NEW.product_terms_hash,NEW.partial_withdrawal_limit_rate,NEW.partial_withdrawal_limit_count,NEW.withdrawn_interest_forfeiture,NEW.break_forfeits_all_interest,NEW.creation_idempotency_key,NEW.creation_request_hash)
         IS DISTINCT FROM (OLD.tenant_id,OLD.id,OLD.savings_account_id,OLD.customer_id,OLD.target_amount,OLD.currency,OLD.target_date,OLD.product_terms_hash,OLD.partial_withdrawal_limit_rate,OLD.partial_withdrawal_limit_count,OLD.withdrawn_interest_forfeiture,OLD.break_forfeits_all_interest,OLD.creation_idempotency_key,OLD.creation_request_hash)
      THEN RAISE EXCEPTION 'Savings goal contract is immutable'; END IF;
      IF OLD.status<>'ACTIVE' AND NEW.status<>OLD.status THEN RAISE EXCEPTION 'Terminal savings goal status is immutable'; END IF;
      RETURN NEW;
    END $fn$;
    CREATE TRIGGER protect_goal BEFORE DELETE OR UPDATE ON savings_goals FOR EACH ROW EXECUTE FUNCTION savings_protect_goal();

    CREATE OR REPLACE FUNCTION savings_validate_account() RETURNS trigger LANGUAGE plpgsql AS $fn$
    DECLARE v savings_product_versions%ROWTYPE;
    BEGIN
      IF TG_OP='UPDATE' THEN
        IF (NEW.tenant_id,NEW.id,NEW.customer_id,NEW.currency,NEW.savings_product_id,NEW.product_version_id,NEW.ledger_entity_id,NEW.ledger_book_id,NEW.ledger_account_id,NEW.opening_sequence,NEW.opening_idempotency_key,NEW.opening_request_hash)
           IS DISTINCT FROM (OLD.tenant_id,OLD.id,OLD.customer_id,OLD.currency,OLD.savings_product_id,OLD.product_version_id,OLD.ledger_entity_id,OLD.ledger_book_id,OLD.ledger_account_id,OLD.opening_sequence,OLD.opening_idempotency_key,OLD.opening_request_hash)
        THEN RAISE EXCEPTION 'Account identity/contract/ledger binding is immutable'; END IF;
        NEW.version=OLD.version+1;
      ELSE
        SELECT * INTO v FROM savings_product_versions WHERE tenant_id=NEW.tenant_id AND id=NEW.product_version_id FOR SHARE;
        IF NOT FOUND OR v.savings_product_id<>NEW.savings_product_id OR v.product_type NOT IN ('ORDINARY','TARGET') OR v.currency<>NEW.currency OR v.status<>'PUBLISHED' OR NOT v.is_current OR now()<v.effective_from OR (v.effective_to IS NOT NULL AND now()>=v.effective_to)
        THEN RAISE EXCEPTION 'Account needs a current published ordinary or target product version'; END IF;
        IF NEW.held_balance<>0 OR NEW.current_balance<>0 THEN RAISE EXCEPTION 'Initial account balances must be zero'; END IF;
      END IF;
      RETURN NEW;
    END $fn$;
  `);
}

export function down(): Promise<never> {
  return Promise.reject(
    new Error("SV-03 target-savings migration is forward-only"),
  );
}
