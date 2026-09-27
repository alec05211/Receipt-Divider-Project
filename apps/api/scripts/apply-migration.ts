import { readFile } from "node:fs/promises";
import postgres from "postgres";

const databaseUrl = process.env.DATABASE_URL;
const migrationPath = process.argv[2];
if (!databaseUrl) throw new Error("DATABASE_URL is required");
if (!migrationPath) throw new Error("Pass a migration file path");

const sql = postgres(databaseUrl, { max: 1, prepare: false, ssl: "require", connect_timeout: 10 });
try {
  await sql.unsafe(await readFile(migrationPath, "utf8"));
  console.log(`Applied ${migrationPath}`);
} finally {
  await sql.end();
}
