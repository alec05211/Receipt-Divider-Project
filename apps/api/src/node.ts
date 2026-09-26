import { serve } from "@hono/node-server";
import { createApp } from "./app.js";
import { MemoryRepository } from "./memory-repository.js";
import { PostgresRepository } from "./postgres-repository.js";

const port = Number(process.env.PORT ?? 8787);
const databaseUrl = process.env.DATABASE_URL;
const allowDevelopmentAuth = process.env.ALLOW_INSECURE_DEV_AUTH === "true";

if (!allowDevelopmentAuth) {
  throw new Error("No production identity verifier is configured. For local work only, set ALLOW_INSECURE_DEV_AUTH=true.");
}

const repository = databaseUrl ? new PostgresRepository(databaseUrl) : new MemoryRepository();
const app = createApp(repository, async (context) => context.req.header("x-user-id") ?? null);

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`Receipt Divider API listening on http://localhost:${info.port}`);
  console.log(databaseUrl ? "Using PostgreSQL" : "Using non-persistent in-memory storage");
});
