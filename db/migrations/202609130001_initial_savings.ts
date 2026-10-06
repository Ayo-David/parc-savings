import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import type { Knex } from "knex";

const canonicalSnapshotHash =
  "b2fa4579e2e87c81ed4b70182729fdf49ad41f85fc7e1070c370057f7c31edac";
export const config = { transaction: false };

export async function up(knex: Knex): Promise<void> {
  if (await knex.schema.hasTable("savings_products"))
    throw new Error(
      "Existing Savings database requires a separately verified baseline approval",
    );
  await knex.raw(`DO $roles$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='parc_savings_runtime') THEN CREATE ROLE parc_savings_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='parc_savings_worker') THEN CREATE ROLE parc_savings_worker NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='parc_savings_readonly') THEN CREATE ROLE parc_savings_readonly NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS; END IF;
  END $roles$;`);
  const sql = await readFile(
    fileURLToPath(new URL("../schema/current.sql", import.meta.url)),
    "utf8",
  );
  if (createHash("sha256").update(sql).digest("hex") !== canonicalSnapshotHash)
    throw new Error("Savings schema snapshot hash mismatch");
  await knex.raw(sql);
  await knex.raw("SET search_path TO public");
  await knex.raw(`GRANT USAGE ON SCHEMA public TO parc_savings_runtime,parc_savings_worker,parc_savings_readonly;
    GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA public TO parc_savings_runtime,parc_savings_worker;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO parc_savings_readonly;
    GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO parc_savings_runtime,parc_savings_worker;`);
}
export function down(): Promise<never> {
  return Promise.reject(new Error("Savings baseline is forward-only"));
}
