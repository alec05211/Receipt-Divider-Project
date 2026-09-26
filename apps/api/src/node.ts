import { serve } from "@hono/node-server";
import { createApp } from "./app.js";
import { MemoryRepository } from "./memory-repository.js";
import { PostgresRepository } from "./postgres-repository.js";
import { createSupabaseAuthenticator } from "./supabase-auth.js";

const port = Number(process.env.PORT ?? 8787);
const databaseUrl = process.env.DATABASE_URL;
const supabaseUrl = process.env.SUPABASE_URL;
const allowDevelopmentAuth = process.env.ALLOW_INSECURE_DEV_AUTH === "true";

if (!allowDevelopmentAuth && !supabaseUrl) throw new Error("SUPABASE_URL is required when development authentication is disabled.");

const repository = databaseUrl ? new PostgresRepository(databaseUrl) : new MemoryRepository();
const authenticate = allowDevelopmentAuth
  ? async (context: Parameters<ReturnType<typeof createSupabaseAuthenticator>>[0]) => context.req.header("x-user-id") ?? null
  : createSupabaseAuthenticator(supabaseUrl!);
const app = createApp(repository, authenticate);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`Receipt Divider API listening on http://localhost:${info.port}`);
  console.log(databaseUrl ? "Using PostgreSQL" : "Using non-persistent in-memory storage");
});
