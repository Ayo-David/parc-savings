import type { Knex } from "knex";
const compiledMigrations = process.env.KNEX_MIGRATIONS_COMPILED === "true";
const config: Knex.Config = {
  client: "pg",
  connection: process.env.DATABASE_URL ?? "postgresql:///parc_savings",
  migrations: {
    // The knex CLI changes into the knexfile's directory (dist/ when compiled).
    directory: "./db/migrations",
    extension: compiledMigrations ? "js" : "ts",
    // Only load runnable files; the build also emits .d.ts declarations here.
    loadExtensions: compiledMigrations ? [".js"] : [".ts"],
  },
};
export default config;
