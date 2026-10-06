import knex, { type Knex } from "knex";
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
