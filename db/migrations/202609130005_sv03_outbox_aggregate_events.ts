import type { Knex } from "knex";

export async function up(knex: Knex): Promise<void> {
  await knex.raw(`
    ALTER TABLE savings_outbox_events
      DROP CONSTRAINT IF EXISTS savings_outbox_events_tenant_id_aggregate_type_aggregate_id_key;
    CREATE UNIQUE INDEX IF NOT EXISTS uq_savings_outbox_aggregate_fact
      ON savings_outbox_events(tenant_id,aggregate_type,aggregate_id,event_type,aggregate_version);
  `);
}

export function down(): Promise<never> {
  return Promise.reject(
    new Error("Savings outbox aggregate-fact migration is forward-only"),
  );
}
