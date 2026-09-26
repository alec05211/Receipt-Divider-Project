import { Hono } from "hono";
import { createApp } from "../../../apps/api/src/app.ts";
import { PostgresRepository } from "../../../apps/api/src/postgres-repository.ts";
import { createSupabaseAuthenticator } from "../../../apps/api/src/supabase-auth.ts";

const databaseUrl = Deno.env.get("SUPABASE_DB_URL");
const supabaseUrl = Deno.env.get("SUPABASE_URL");

if (!databaseUrl) throw new Error("SUPABASE_DB_URL is required");
if (!supabaseUrl) throw new Error("SUPABASE_URL is required");

const repository = new PostgresRepository(databaseUrl);
const ledgerApi = createApp(repository, createSupabaseAuthenticator(supabaseUrl));

// Supabase forwards the function-name prefix as part of the request path.
const app = new Hono();
app.route("/ledger-api", ledgerApi);

export default { fetch: app.fetch };

