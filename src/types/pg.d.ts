// Minimal typing for the part of node-postgres used directly (knex wraps the rest).
declare module "pg" {
  const pg: {
    types: {
      setTypeParser(oid: number, parse: (value: string) => unknown): void;
    };
  };
  export default pg;
}
