import type { Knex } from "knex";

export async function up(knex: Knex): Promise<void> {
  if (await knex.schema.hasColumn("fixed_deposits", "placement_request_hash"))
    return;
  await knex.raw(`
    ALTER TABLE savings_accounts ADD COLUMN product_type savings_product_type_enum;
    UPDATE savings_accounts a SET product_type=v.product_type FROM savings_product_versions v WHERE v.tenant_id=a.tenant_id AND v.id=a.product_version_id;
    ALTER TABLE savings_accounts ALTER COLUMN product_type SET NOT NULL;
    DROP INDEX uq_savings_one_ordinary_account;
    CREATE UNIQUE INDEX uq_savings_one_customer_product_account ON savings_accounts(tenant_id,customer_id,savings_product_id,currency) WHERE deleted_at IS NULL AND product_type IN ('ORDINARY','TARGET');

    ALTER TABLE fixed_deposits DROP CONSTRAINT chk_fixed_deposit_amounts;
    ALTER TABLE fixed_deposits DROP CONSTRAINT chk_fixed_deposit_principal;
    ALTER TABLE fixed_deposits
      ALTER COLUMN principal_amount TYPE bigint USING round(principal_amount*100)::bigint,
      ALTER COLUMN interest_rate TYPE numeric(18,10),
      ALTER COLUMN interest_amount TYPE numeric(30,12),
      ALTER COLUMN maturity_amount TYPE bigint USING round(maturity_amount*100)::bigint,
      ADD COLUMN placement_idempotency_key varchar(255),
      ADD COLUMN placement_request_hash char(64),
      ADD COLUMN correlation_id uuid,
      ADD COLUMN ledger_journal_id uuid,
      ADD COLUMN ledger_request_hash char(64),
      ADD COLUMN ledger_posted_at timestamptz,
      ADD COLUMN quote_id uuid,
      ADD COLUMN quote_hash char(64),
      ADD COLUMN quote_expires_at timestamptz,
      ADD COLUMN early_liquidation_allowed boolean NOT NULL DEFAULT true,
      ADD COLUMN early_liquidation_penalty_rate numeric(18,10) NOT NULL DEFAULT 0,
      ADD COLUMN maturity_instruction_cutoff_days integer NOT NULL DEFAULT 1,
      ADD COLUMN aggregate_version bigint NOT NULL DEFAULT 1,
      ADD CONSTRAINT fixed_deposit_principal_minor CHECK (principal_amount>0),
      ADD CONSTRAINT fixed_deposit_unposted_interest CHECK (interest_amount>=0),
      ADD CONSTRAINT fixed_deposit_maturity_minor CHECK (maturity_amount>=principal_amount),
      ADD CONSTRAINT fixed_deposit_placement_hash CHECK (placement_request_hash IS NULL OR placement_request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT fixed_deposit_ledger_hash CHECK (ledger_request_hash IS NULL OR ledger_request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT fixed_deposit_quote_hash CHECK (quote_hash IS NULL OR quote_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT fixed_deposit_quote_evidence CHECK (quote_id IS NULL OR (quote_hash IS NOT NULL AND quote_expires_at IS NOT NULL)),
      ADD CONSTRAINT fixed_deposit_activation_evidence CHECK (status<>'ACTIVE' OR (placement_idempotency_key IS NOT NULL AND placement_request_hash IS NOT NULL AND correlation_id IS NOT NULL AND ledger_transaction_id IS NOT NULL AND ledger_journal_id IS NOT NULL AND ledger_request_hash IS NOT NULL AND ledger_posted_at IS NOT NULL)),
      ADD CONSTRAINT fixed_deposit_liquidation_policy CHECK (early_liquidation_penalty_rate>=0 AND early_liquidation_penalty_rate<=100),
      ADD CONSTRAINT fixed_deposit_cutoff CHECK (maturity_instruction_cutoff_days>=0),
      ADD CONSTRAINT fixed_deposit_aggregate_version CHECK (aggregate_version>0);
    CREATE UNIQUE INDEX uq_fixed_deposit_placement_idempotency ON fixed_deposits(tenant_id,placement_idempotency_key) WHERE placement_idempotency_key IS NOT NULL;
    CREATE INDEX idx_fixed_deposit_due_active ON fixed_deposits(tenant_id,maturity_date,id) WHERE status='ACTIVE';

    CREATE TABLE fixed_deposit_quotes (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, customer_id uuid NOT NULL,
      quote_type text NOT NULL CHECK (quote_type IN ('PLACEMENT','LIQUIDATION')), fixed_deposit_id uuid,
      product_version_id uuid NOT NULL, principal_minor bigint NOT NULL CHECK (principal_minor>0), currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
      tenure_days integer NOT NULL CHECK (tenure_days>0), interest_rate numeric(18,10) NOT NULL CHECK (interest_rate>=0),
      expected_interest_unrounded numeric(30,12) NOT NULL CHECK (expected_interest_unrounded>=0), expected_interest_minor bigint NOT NULL CHECK (expected_interest_minor>=0),
      penalty_minor bigint NOT NULL DEFAULT 0 CHECK (penalty_minor>=0), payout_minor bigint NOT NULL CHECK (payout_minor>=0),
      calculation_snapshot jsonb NOT NULL CHECK (jsonb_typeof(calculation_snapshot)='object'), quote_hash char(64) NOT NULL CHECK (quote_hash ~ '^[a-f0-9]{64}$'),
      request_hash char(64) NOT NULL CHECK (request_hash ~ '^[a-f0-9]{64}$'), idempotency_key varchar(255) NOT NULL,
      expires_at timestamptz NOT NULL, consumed_at timestamptz, correlation_id uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE(tenant_id,id), UNIQUE(tenant_id,idempotency_key), UNIQUE(tenant_id,quote_hash),
      FOREIGN KEY (tenant_id,product_version_id) REFERENCES savings_product_versions(tenant_id,id),
      FOREIGN KEY (tenant_id,fixed_deposit_id) REFERENCES fixed_deposits(tenant_id,id),
      CHECK ((quote_type='PLACEMENT' AND fixed_deposit_id IS NULL) OR (quote_type='LIQUIDATION' AND fixed_deposit_id IS NOT NULL)),
      CHECK (expires_at>created_at), CHECK (consumed_at IS NULL OR consumed_at>=created_at)
    );
    CREATE INDEX idx_fixed_deposit_quote_expiry ON fixed_deposit_quotes(tenant_id,expires_at) WHERE consumed_at IS NULL;
    ALTER TABLE fixed_deposit_quotes ENABLE ROW LEVEL SECURITY;
    ALTER TABLE fixed_deposit_quotes FORCE ROW LEVEL SECURITY;
    CREATE POLICY fixed_deposit_quotes_tenant_policy ON fixed_deposit_quotes USING (tenant_id=NULLIF(current_setting('app.current_tenant_id',true),'')::uuid) WITH CHECK (tenant_id=NULLIF(current_setting('app.current_tenant_id',true),'')::uuid);
    GRANT SELECT,INSERT,UPDATE ON fixed_deposit_quotes TO parc_savings_runtime,parc_savings_worker;
    GRANT SELECT ON fixed_deposit_quotes TO parc_savings_readonly;

    ALTER TABLE fixed_deposit_liquidations DROP CONSTRAINT fixed_deposit_liquidations_check;
    ALTER TABLE fixed_deposit_liquidations DROP CONSTRAINT fixed_deposit_liquidations_check1;
    ALTER TABLE fixed_deposit_liquidations DROP COLUMN net_payout;
    ALTER TABLE fixed_deposit_liquidations
      ALTER COLUMN principal_amount TYPE bigint USING round(principal_amount*100)::bigint,
      ALTER COLUMN interest_due TYPE bigint USING round(interest_due*100)::bigint,
      ALTER COLUMN interest_clawback TYPE bigint USING round(interest_clawback*100)::bigint,
      ALTER COLUMN penalty_amount TYPE bigint USING round(penalty_amount*100)::bigint,
      ALTER COLUMN tax_amount TYPE bigint USING round(tax_amount*100)::bigint,
      ADD COLUMN net_payout bigint GENERATED ALWAYS AS (principal_amount+interest_due-interest_clawback-penalty_amount-tax_amount) STORED,
      ADD COLUMN request_hash char(64),
      ADD COLUMN quote_id uuid,
      ADD COLUMN quote_hash char(64),
      ADD COLUMN quote_expires_at timestamptz,
      ADD COLUMN ledger_journal_id uuid,
      ADD COLUMN ledger_request_hash char(64),
      ADD COLUMN ledger_posted_at timestamptz,
      ADD COLUMN authority_type text NOT NULL DEFAULT 'PRODUCT_POLICY',
      ADD COLUMN approval_id uuid,
      ADD CONSTRAINT fixed_deposit_liquidation_request_hash CHECK (request_hash IS NULL OR request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT fixed_deposit_liquidation_quote_hash CHECK (quote_hash IS NULL OR quote_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT fixed_deposit_liquidation_authority CHECK (authority_type IN ('PRODUCT_POLICY','TENANT_APPROVAL')),
      ADD CONSTRAINT fixed_deposit_liquidation_approval CHECK (authority_type<>'TENANT_APPROVAL' OR approval_id IS NOT NULL),
      ADD CONSTRAINT fixed_deposit_liquidation_maker_checker CHECK (approved_by IS NULL OR approved_by<>created_by),
      ADD CONSTRAINT fixed_deposit_liquidation_authority_evidence CHECK (status NOT IN ('APPROVED','POSTING','SUCCESSFUL') OR authority_type='PRODUCT_POLICY' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
      ADD CONSTRAINT fixed_deposit_liquidation_success_evidence CHECK (status<>'SUCCESSFUL' OR (ledger_transaction_id IS NOT NULL AND ledger_journal_id IS NOT NULL AND ledger_request_hash IS NOT NULL AND ledger_posted_at IS NOT NULL AND processed_at IS NOT NULL));
    CREATE UNIQUE INDEX uq_fixed_deposit_open_liquidation ON fixed_deposit_liquidations(tenant_id,fixed_deposit_id) WHERE status NOT IN ('FAILED','REJECTED','CANCELLED');

    ALTER TABLE fixed_deposit_maturities DROP COLUMN net_amount;
    ALTER TABLE fixed_deposit_maturities
      ALTER COLUMN principal_amount TYPE bigint USING round(principal_amount*100)::bigint,
      ALTER COLUMN unpaid_interest TYPE bigint USING round(unpaid_interest*100)::bigint,
      ALTER COLUMN tax_amount TYPE bigint USING round(tax_amount*100)::bigint,
      ADD COLUMN net_amount bigint GENERATED ALWAYS AS (principal_amount+unpaid_interest-tax_amount) STORED,
      ADD COLUMN request_hash char(64),
      ADD COLUMN ledger_journal_id uuid,
      ADD COLUMN ledger_request_hash char(64),
      ADD COLUMN ledger_posted_at timestamptz,
      ADD COLUMN system_authority text NOT NULL DEFAULT 'SCHEDULED_MATURITY',
      ADD CONSTRAINT fixed_deposit_maturity_request_hash CHECK (request_hash IS NULL OR request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT fixed_deposit_maturity_authority CHECK (system_authority='SCHEDULED_MATURITY'),
      ADD CONSTRAINT fixed_deposit_maturity_success_evidence CHECK (status<>'SUCCESSFUL' OR (ledger_transaction_id IS NOT NULL AND ledger_journal_id IS NOT NULL AND ledger_request_hash IS NOT NULL AND ledger_posted_at IS NOT NULL AND processed_at IS NOT NULL));

    DROP TRIGGER immutable_row ON fixed_deposit_instructions;
    ALTER TABLE fixed_deposit_instructions
      ADD COLUMN idempotency_key varchar(255),
      ADD COLUMN request_hash char(64),
      ADD COLUMN correlation_id uuid,
      ADD COLUMN superseded_at timestamptz,
      ADD CONSTRAINT fixed_deposit_instruction_hash CHECK (request_hash IS NULL OR request_hash ~ '^[a-f0-9]{64}$');
    CREATE UNIQUE INDEX uq_fixed_deposit_instruction_idempotency ON fixed_deposit_instructions(tenant_id,idempotency_key) WHERE idempotency_key IS NOT NULL;
    CREATE UNIQUE INDEX uq_fixed_deposit_current_instruction ON fixed_deposit_instructions(tenant_id,fixed_deposit_id) WHERE superseded_at IS NULL;
    CREATE OR REPLACE FUNCTION savings_protect_fd_instruction() RETURNS trigger LANGUAGE plpgsql AS $fn$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Fixed-deposit instructions cannot be deleted'; END IF;
      IF (to_jsonb(NEW)-ARRAY['superseded_at']) IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['superseded_at']) OR OLD.superseded_at IS NOT NULL OR NEW.superseded_at IS NULL
      THEN RAISE EXCEPTION 'Fixed-deposit instruction is immutable except for one-time supersession'; END IF;
      RETURN NEW;
    END $fn$;
    CREATE TRIGGER protect_instruction BEFORE DELETE OR UPDATE ON fixed_deposit_instructions FOR EACH ROW EXECUTE FUNCTION savings_protect_fd_instruction();

    ALTER TABLE fixed_deposit_renewals
      ALTER COLUMN principal_amount TYPE bigint USING round(principal_amount*100)::bigint,
      ALTER COLUMN interest_amount TYPE bigint USING round(interest_amount*100)::bigint,
      ALTER COLUMN interest_rate TYPE numeric(18,10);
    ALTER TABLE fixed_deposit_interest_payments
      ALTER COLUMN amount TYPE bigint USING round(amount*100)::bigint;

    CREATE OR REPLACE FUNCTION savings_protect_fixed_deposit() RETURNS trigger LANGUAGE plpgsql AS $fn$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Fixed deposits cannot be deleted'; END IF;
      IF OLD.status IN ('ACTIVE','MATURED','LIQUIDATED','RENEWED') AND
        (NEW.tenant_id,NEW.id,NEW.savings_account_id,NEW.customer_id,NEW.principal_amount,NEW.currency,NEW.interest_rate,NEW.tenure_days,NEW.start_date,NEW.maturity_date,NEW.product_version_id,NEW.fixed_deposit_rate_id,NEW.contract_reference,NEW.accepted_at,NEW.accepted_terms_hash,NEW.terms_snapshot,NEW.day_count_basis,NEW.compounding_method,NEW.early_liquidation_allowed,NEW.early_liquidation_penalty_rate,NEW.maturity_instruction_cutoff_days,NEW.placement_idempotency_key,NEW.placement_request_hash)
        IS DISTINCT FROM
        (OLD.tenant_id,OLD.id,OLD.savings_account_id,OLD.customer_id,OLD.principal_amount,OLD.currency,OLD.interest_rate,OLD.tenure_days,OLD.start_date,OLD.maturity_date,OLD.product_version_id,OLD.fixed_deposit_rate_id,OLD.contract_reference,OLD.accepted_at,OLD.accepted_terms_hash,OLD.terms_snapshot,OLD.day_count_basis,OLD.compounding_method,OLD.early_liquidation_allowed,OLD.early_liquidation_penalty_rate,OLD.maturity_instruction_cutoff_days,OLD.placement_idempotency_key,OLD.placement_request_hash)
      THEN RAISE EXCEPTION 'Active fixed-deposit contract is immutable'; END IF;
      IF OLD.status IN ('MATURED','LIQUIDATED','RENEWED','CANCELLED','WITHDRAWN') AND NEW.status<>OLD.status THEN RAISE EXCEPTION 'Terminal fixed-deposit status is immutable'; END IF;
      IF NEW.status<>OLD.status AND NOT ((OLD.status='PENDING' AND NEW.status IN ('ACTIVE','CANCELLED')) OR (OLD.status='ACTIVE' AND NEW.status IN ('MATURED','LIQUIDATED','RENEWED','CANCELLED'))) THEN RAISE EXCEPTION 'Invalid fixed-deposit transition'; END IF;
      IF NEW.aggregate_version<=OLD.aggregate_version THEN NEW.aggregate_version=OLD.aggregate_version+1; END IF;
      RETURN NEW;
    END $fn$;
    CREATE TRIGGER protect_fixed_deposit BEFORE DELETE OR UPDATE ON fixed_deposits FOR EACH ROW EXECUTE FUNCTION savings_protect_fixed_deposit();

    CREATE OR REPLACE FUNCTION savings_validate_fixed_deposit() RETURNS trigger LANGUAGE plpgsql AS $fn$
    DECLARE a savings_accounts%ROWTYPE; v savings_product_versions%ROWTYPE; r fixed_deposit_rates%ROWTYPE;
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'FD contracts cannot be deleted'; END IF;
      IF TG_OP='UPDATE' THEN
        IF (to_jsonb(NEW)-ARRAY['status','interest_amount','maturity_amount','ledger_transaction_id','ledger_journal_id','ledger_request_hash','ledger_posted_at','matured_at','withdrawn_at','updated_at','updated_by','aggregate_version']) IS DISTINCT FROM
           (to_jsonb(OLD)-ARRAY['status','interest_amount','maturity_amount','ledger_transaction_id','ledger_journal_id','ledger_request_hash','ledger_posted_at','matured_at','withdrawn_at','updated_at','updated_by','aggregate_version'])
        THEN RAISE EXCEPTION 'FD contract terms are immutable'; END IF;
        IF OLD.status IN ('WITHDRAWN','RENEWED','CANCELLED','LIQUIDATED','MATURED') THEN RAISE EXCEPTION 'Terminal FD cannot change'; END IF;
      ELSE
        SELECT * INTO a FROM savings_accounts WHERE tenant_id=NEW.tenant_id AND id=NEW.savings_account_id;
        SELECT * INTO v FROM savings_product_versions WHERE tenant_id=NEW.tenant_id AND id=NEW.product_version_id;
        SELECT * INTO r FROM fixed_deposit_rates WHERE tenant_id=NEW.tenant_id AND id=NEW.fixed_deposit_rate_id;
        IF a.id IS NULL OR v.id IS NULL OR r.id IS NULL OR a.product_version_id<>NEW.product_version_id OR v.product_type<>'FIXED_DEPOSIT'
           OR r.product_version_id<>NEW.product_version_id OR r.interest_rate<>NEW.interest_rate
           OR NEW.tenure_days<(v.terms->>'minimumTenureDays')::integer OR NEW.tenure_days>(v.terms->>'maximumTenureDays')::integer
           OR NEW.principal_amount<r.minimum_amount OR (r.maximum_amount IS NOT NULL AND NEW.principal_amount>r.maximum_amount)
           OR NEW.accepted_at<r.effective_from OR (r.effective_to IS NOT NULL AND NEW.accepted_at>=r.effective_to)
        THEN RAISE EXCEPTION 'FD contract does not match account/product/rate/tenure/amount/effective period'; END IF;
      END IF;
      IF NEW.status NOT IN ('PENDING','CANCELLED') AND NEW.ledger_transaction_id IS NULL THEN RAISE EXCEPTION 'Funded FD requires ledger posting'; END IF;
      RETURN NEW;
    END $fn$;

    CREATE OR REPLACE FUNCTION savings_validate_account() RETURNS trigger LANGUAGE plpgsql AS $fn$
    DECLARE v savings_product_versions%ROWTYPE;
    BEGIN
      IF TG_OP='UPDATE' THEN
        IF (NEW.tenant_id,NEW.id,NEW.customer_id,NEW.currency,NEW.savings_product_id,NEW.product_version_id,NEW.product_type,NEW.ledger_entity_id,NEW.ledger_book_id,NEW.ledger_account_id,NEW.opening_sequence,NEW.opening_idempotency_key,NEW.opening_request_hash)
           IS DISTINCT FROM (OLD.tenant_id,OLD.id,OLD.customer_id,OLD.currency,OLD.savings_product_id,OLD.product_version_id,OLD.product_type,OLD.ledger_entity_id,OLD.ledger_book_id,OLD.ledger_account_id,OLD.opening_sequence,OLD.opening_idempotency_key,OLD.opening_request_hash)
        THEN RAISE EXCEPTION 'Account identity/contract/ledger binding is immutable'; END IF;
        NEW.version=OLD.version+1;
      ELSE
        SELECT * INTO v FROM savings_product_versions WHERE tenant_id=NEW.tenant_id AND id=NEW.product_version_id FOR SHARE;
        IF NOT FOUND OR v.savings_product_id<>NEW.savings_product_id OR v.product_type NOT IN ('ORDINARY','TARGET','FIXED_DEPOSIT') OR v.currency<>NEW.currency OR v.status<>'PUBLISHED' OR NOT v.is_current OR now()<v.effective_from OR (v.effective_to IS NOT NULL AND now()>=v.effective_to)
        THEN RAISE EXCEPTION 'Account needs a current published supported savings product version'; END IF;
        IF NEW.held_balance<>0 OR NEW.current_balance<>0 THEN RAISE EXCEPTION 'Initial account balances must be zero'; END IF;
        IF NEW.product_type<>v.product_type THEN RAISE EXCEPTION 'Account product type must match its version'; END IF;
      END IF;
      RETURN NEW;
    END $fn$;
  `);
}

export function down(): Promise<never> {
  return Promise.reject(
    new Error("SV-04 fixed-deposit migration is forward-only"),
  );
}
