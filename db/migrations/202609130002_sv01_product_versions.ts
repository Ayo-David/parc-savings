import type { Knex } from "knex";
export const config = { transaction: false };

export async function up(knex: Knex): Promise<void> {
  await knex.raw(`
    ALTER TYPE savings_product_type_enum ADD VALUE IF NOT EXISTS 'ORDINARY';
    ALTER TYPE savings_product_type_enum ADD VALUE IF NOT EXISTS 'RECURRING';
  `);
  if (await knex.schema.hasColumn("savings_product_versions", "annual_rate"))
    return;
  await knex.raw(`
    ALTER TABLE savings_products
      ALTER COLUMN minimum_balance TYPE bigint USING round(minimum_balance*100)::bigint,
      ALTER COLUMN minimum_deposit TYPE bigint USING round(minimum_deposit*100)::bigint,
      ALTER COLUMN maximum_balance TYPE bigint USING CASE WHEN maximum_balance IS NULL THEN NULL ELSE round(maximum_balance*100)::bigint END,
      ALTER COLUMN interest_rate TYPE numeric(18,10),
      ADD COLUMN lifecycle_status text NOT NULL DEFAULT 'DRAFT' CHECK (lifecycle_status IN ('DRAFT','ACTIVE','RETIRED')),
      ADD COLUMN idempotency_key varchar(255),
      ADD COLUMN request_hash char(64) CHECK (request_hash IS NULL OR request_hash ~ '^[a-f0-9]{64}$');
    CREATE UNIQUE INDEX IF NOT EXISTS uq_savings_product_idempotency ON savings_products(tenant_id,idempotency_key) WHERE idempotency_key IS NOT NULL;

    DROP TRIGGER protect_version ON savings_product_versions;
    ALTER TABLE savings_product_versions DROP CONSTRAINT savings_product_versions_status_check;
    ALTER TABLE savings_product_versions
      ALTER COLUMN minimum_balance TYPE bigint USING round(minimum_balance*100)::bigint,
      ALTER COLUMN minimum_deposit TYPE bigint USING round(minimum_deposit*100)::bigint,
      ALTER COLUMN maximum_balance TYPE bigint USING CASE WHEN maximum_balance IS NULL THEN NULL ELSE round(maximum_balance*100)::bigint END,
      ALTER COLUMN minimum_balance DROP NOT NULL,
      ALTER COLUMN minimum_balance DROP DEFAULT,
      ADD COLUMN annual_rate numeric(18,10) NOT NULL DEFAULT 0,
      ADD COLUMN is_current boolean NOT NULL DEFAULT false,
      ADD COLUMN idempotency_key varchar(255),
      ADD COLUMN request_hash char(64) CHECK (request_hash IS NULL OR request_hash ~ '^[a-f0-9]{64}$'),
      ADD COLUMN approval_id uuid,
      ADD COLUMN approval_payload_hash char(64),
      ADD COLUMN approval_maker_id uuid,
      ADD COLUMN approval_checker_ids uuid[],
      ADD COLUMN approved_authority_level integer,
      ADD COLUMN published_by uuid,
      ADD COLUMN publication_idempotency_key varchar(255),
      ADD COLUMN publication_request_hash char(64) CHECK (publication_request_hash IS NULL OR publication_request_hash ~ '^[a-f0-9]{64}$'),
      ADD CONSTRAINT savings_version_status CHECK (status IN ('DRAFT','PENDING_APPROVAL','PUBLISHED','RETIRED')),
      ADD CONSTRAINT savings_ordinary_no_minimum CHECK (product_type <> 'ORDINARY' OR minimum_balance IS NULL),
      ADD CONSTRAINT savings_publication_evidence CHECK (status NOT IN ('PUBLISHED','RETIRED') OR (approval_id IS NOT NULL AND approval_payload_hash IS NOT NULL AND approval_maker_id IS NOT NULL AND cardinality(approval_checker_ids)>0 AND approved_authority_level>0 AND published_by IS NOT NULL AND published_at IS NOT NULL)),
      ADD CONSTRAINT savings_maker_checker CHECK (approval_checker_ids IS NULL OR NOT approval_maker_id = ANY(approval_checker_ids));
    CREATE UNIQUE INDEX uq_savings_version_idempotency ON savings_product_versions(tenant_id,idempotency_key) WHERE idempotency_key IS NOT NULL;
    CREATE UNIQUE INDEX uq_savings_publication_idempotency ON savings_product_versions(tenant_id,publication_idempotency_key) WHERE publication_idempotency_key IS NOT NULL;
    CREATE UNIQUE INDEX uq_savings_current_version ON savings_product_versions(tenant_id,savings_product_id) WHERE is_current;
    CREATE INDEX idx_savings_version_catalog ON savings_product_versions(tenant_id,product_type,status,effective_from);

    ALTER TABLE savings_product_rates
      ALTER COLUMN interest_rate TYPE numeric(18,10),
      ALTER COLUMN minimum_balance TYPE bigint USING CASE WHEN minimum_balance IS NULL THEN NULL ELSE round(minimum_balance*100)::bigint END,
      ALTER COLUMN maximum_balance TYPE bigint USING CASE WHEN maximum_balance IS NULL THEN NULL ELSE round(maximum_balance*100)::bigint END;
    ALTER TABLE savings_product_tiers
      ALTER COLUMN interest_rate TYPE numeric(18,10),
      ALTER COLUMN minimum_balance TYPE bigint USING CASE WHEN minimum_balance IS NULL THEN NULL ELSE round(minimum_balance*100)::bigint END,
      ALTER COLUMN maximum_balance TYPE bigint USING CASE WHEN maximum_balance IS NULL THEN NULL ELSE round(maximum_balance*100)::bigint END;
    ALTER TABLE savings_product_fees
      ALTER COLUMN percentage_rate TYPE numeric(18,10),
      ALTER COLUMN fixed_amount TYPE bigint USING CASE WHEN fixed_amount IS NULL THEN NULL ELSE round(fixed_amount*100)::bigint END,
      ALTER COLUMN minimum_fee TYPE bigint USING round(minimum_fee*100)::bigint,
      ALTER COLUMN maximum_fee TYPE bigint USING CASE WHEN maximum_fee IS NULL THEN NULL ELSE round(maximum_fee*100)::bigint END;
    ALTER TABLE fixed_deposit_rates
      ALTER COLUMN interest_rate TYPE numeric(18,10),
      ALTER COLUMN minimum_amount TYPE bigint USING round(minimum_amount*100)::bigint,
      ALTER COLUMN maximum_amount TYPE bigint USING CASE WHEN maximum_amount IS NULL THEN NULL ELSE round(maximum_amount*100)::bigint END;

    CREATE OR REPLACE FUNCTION savings_protect_version() RETURNS trigger LANGUAGE plpgsql AS $fn$
    BEGIN
      IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Savings product versions cannot be deleted'; END IF;
      IF OLD.status IN ('PUBLISHED','RETIRED') AND NOT (OLD.status='PUBLISHED' AND NEW.status='RETIRED' AND NEW.is_current=false AND (to_jsonb(NEW)-ARRAY['status','is_current','effective_to','updated_at']::text[])=(to_jsonb(OLD)-ARRAY['status','is_current','effective_to','updated_at']::text[])) THEN RAISE EXCEPTION 'Published savings product versions are immutable'; END IF;
      IF (NEW.tenant_id,NEW.id,NEW.savings_product_id,NEW.version_number) IS DISTINCT FROM (OLD.tenant_id,OLD.id,OLD.savings_product_id,OLD.version_number) THEN RAISE EXCEPTION 'Version identity is immutable'; END IF;
      RETURN NEW;
    END $fn$;
    CREATE TRIGGER protect_version BEFORE DELETE OR UPDATE ON savings_product_versions FOR EACH ROW EXECUTE FUNCTION savings_protect_version();
  `);
}
export function down(): Promise<never> {
  return Promise.reject(
    new Error("SV-01 product-version migration is forward-only"),
  );
}
