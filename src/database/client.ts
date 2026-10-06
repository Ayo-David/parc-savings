import knex, { type Knex } from "knex";
import pg from "pg";

// Keep DATE columns as YYYY-MM-DD; parsing them into local-midnight Dates
// lets the process timezone shift business dates.
const DATE_OID = 1082;
pg.types.setTypeParser(DATE_OID, (value) => value);

export function createDatabase(connection: string): Knex {
  return knex({ client: "pg", connection, pool: { min: 0, max: 10 } });
}
export function withTenantTransaction<T>(
  database: Knex,
  tenantId: string,
  work: (transaction: Knex.Transaction) => Promise<T>,
): Promise<T> {
  return database.transaction(async (transaction) => {
    await transaction.raw("SELECT set_config('app.current_tenant_id',?,true)", [
      tenantId,
    ]);
    return work(transaction);
  });
}
