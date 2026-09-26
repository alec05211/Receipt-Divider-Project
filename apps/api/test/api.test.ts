import assert from "node:assert/strict";
import { test } from "node:test";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from "jose";
import { createApp } from "../src/app.ts";
import { MemoryRepository } from "../src/memory-repository.ts";
import { createSupabaseAuthenticator } from "../src/supabase-auth.ts";

const alex = "00000000-0000-4000-8000-000000000001";
const stranger = "00000000-0000-4000-8000-000000000003";

function request(app: ReturnType<typeof createApp>, path: string, userId: string, init: RequestInit = {}) { return app.request(path, { ...init, headers: { "x-user-id": userId, ...init.headers } }); }
async function jsonRequest(app: ReturnType<typeof createApp>, path: string, userId: string, method: string, body: unknown) { return request(app, path, userId, { method, headers: { "content-type": "application/json" }, body: JSON.stringify(body) }); }

async function setup() {
  const app = createApp(new MemoryRepository(), async (context) => context.req.header("x-user-id") ?? null);
  assert.equal((await jsonRequest(app, "/v1/profile", alex, "PUT", { displayName: "Alex" })).status, 200);
  assert.equal((await jsonRequest(app, "/v1/profile", stranger, "PUT", { displayName: "Stranger" })).status, 200);
  async function person(displayName: string) { const response = await jsonRequest(app, "/v1/people", alex, "POST", { displayName }); assert.equal(response.status, 201); return (await response.json() as { id: string }).id; }
  return { app, alexPerson: await person("Alex"), jamiePerson: await person("Jamie"), morganPerson: await person("Morgan") };
}

test("concurrent general expenses and repayments produce an additive zero-sum ledger", async () => {
  const { app, alexPerson, jamiePerson } = await setup();
  const first = { clientRequestId: "10000000-0000-4000-8000-000000000001", description: "Groceries", transactionDate: "2026-09-18", payerPersonId: alexPerson, currency: "USD", totalCents: 3000, allocations: [{ personId: alexPerson, amountCents: 1000 }, { personId: jamiePerson, amountCents: 2000 }] };
  const second = { clientRequestId: "10000000-0000-4000-8000-000000000002", description: "Supplies", transactionDate: "2026-09-19", payerPersonId: jamiePerson, currency: "USD", totalCents: 2000, items: [{ name: "Cleaning supplies", amountCents: 2000 }], allocations: [{ personId: alexPerson, amountCents: 1000 }, { personId: jamiePerson, amountCents: 1000 }] };
  const responses = await Promise.all([jsonRequest(app, "/v1/expenses", alex, "POST", first), jsonRequest(app, "/v1/expenses", alex, "POST", second)]);
  assert.deepEqual(responses.map((r) => r.status), [201, 201]);
  let snapshot = await (await request(app, "/v1/transactions", alex)).json() as { version: number; expenses: unknown[]; balances: Record<string, number> };
  assert.equal(snapshot.version, 2); assert.equal(snapshot.expenses.length, 2); assert.equal(snapshot.balances[alexPerson], 1000); assert.equal(snapshot.balances[jamiePerson], -1000); assert.equal(Object.values(snapshot.balances).reduce((sum, value) => sum + value, 0), 0);
  assert.equal((await jsonRequest(app, "/v1/payments", alex, "POST", { clientRequestId: "10000000-0000-4000-8000-000000000003", fromPersonId: jamiePerson, toPersonId: alexPerson, amountCents: 1000, transactionDate: "2026-09-21" })).status, 201);
  snapshot = await (await request(app, "/v1/transactions", alex)).json(); assert.equal(snapshot.version, 3); assert.equal(snapshot.balances[alexPerson], 0); assert.equal(snapshot.balances[jamiePerson], 0);
});

test("saved groups are local any-person filters, never ledger containers", async () => {
  const { app, alexPerson, jamiePerson, morganPerson } = await setup();
  const filterResponse = await jsonRequest(app, "/v1/saved-filters", alex, "POST", { name: "Roommates", personIds: [jamiePerson, morganPerson] });
  assert.equal(filterResponse.status, 201); const filterId = (await filterResponse.json() as { id: string }).id;
  const expenses = [
    ["20000000-0000-4000-8000-000000000001", "Dinner", jamiePerson],
    ["20000000-0000-4000-8000-000000000002", "Ticket", morganPerson],
    ["20000000-0000-4000-8000-000000000003", "Solo coffee", alexPerson],
  ];
  for (const [clientRequestId, description, participant] of expenses) assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", { clientRequestId, description, transactionDate: "2026-09-20", payerPersonId: alexPerson, currency: "USD", totalCents: 1000, allocations: [{ personId: participant, amountCents: 1000 }] })).status, 201);
  const all = await (await request(app, "/v1/transactions", alex)).json() as { expenses: unknown[]; balances: Record<string, number> };
  const filtered = await (await request(app, `/v1/transactions?filterId=${filterId}`, alex)).json() as { appliedFilterId: string; expenses: Array<{ description: string }>; balances: Record<string, number> };
  assert.equal(all.expenses.length, 3); assert.equal(filtered.appliedFilterId, filterId); assert.deepEqual(filtered.expenses.map((e) => e.description).sort(), ["Dinner", "Ticket"]); assert.deepEqual(filtered.balances, all.balances);
  assert.equal((await request(app, `/v1/transactions?filterId=${filterId}`, stranger)).status, 404);
});

test("optional evidence is stored in the database boundary and remains owner-private", async () => {
  const { app, alexPerson, jamiePerson } = await setup(); const bytes = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
  const upload = await request(app, "/v1/evidence?kind=ticket_confirmation", alex, { method: "POST", headers: { "content-type": "image/jpeg" }, body: bytes });
  assert.equal(upload.status, 201); const { id } = await upload.json() as { id: string };
  const expense = await jsonRequest(app, "/v1/expenses", alex, "POST", { clientRequestId: "30000000-0000-4000-8000-000000000001", description: "Concert tickets", transactionDate: "2026-09-20", payerPersonId: alexPerson, currency: "USD", totalCents: 5000, evidenceIds: [id], allocations: [{ personId: jamiePerson, amountCents: 5000 }] });
  assert.equal(expense.status, 201); assert.deepEqual((await expense.json() as { evidenceIds: string[] }).evidenceIds, [id]);
  const visible = await request(app, `/v1/evidence/${id}/image`, alex); assert.deepEqual(new Uint8Array(await visible.arrayBuffer()), bytes);
  assert.equal((await request(app, `/v1/evidence/${id}/image`, stranger)).status, 404);
  assert.equal((await request(app, "/v1/evidence?kind=receipt", alex, { method: "POST", headers: { "content-type": "image/png" }, body: bytes })).status, 415);
});

test("idempotency and exact totals protect canonical expenses", async () => {
  const { app, alexPerson, jamiePerson } = await setup();
  const expense = { clientRequestId: "40000000-0000-4000-8000-000000000001", description: "Dinner", transactionDate: "2026-09-20", payerPersonId: alexPerson, currency: "USD", totalCents: 4000, items: [{ name: "Dinner", amountCents: 4000 }], allocations: [{ personId: alexPerson, amountCents: 2000 }, { personId: jamiePerson, amountCents: 2000 }] };
  const first = await jsonRequest(app, "/v1/expenses", alex, "POST", expense), retry = await jsonRequest(app, "/v1/expenses", alex, "POST", expense);
  assert.equal((await first.json() as { id: string }).id, (await retry.json() as { id: string }).id);
  assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", { ...expense, description: "Changed" })).status, 409);
  assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", { ...expense, clientRequestId: "40000000-0000-4000-8000-000000000002", totalCents: 3999 })).status, 422);
});

test("Supabase JWT authentication accepts only signed authenticated-user tokens", async () => {
  const projectUrl = "https://receipt-divider.supabase.co", issuer = `${projectUrl}/auth/v1`, { publicKey, privateKey } = await generateKeyPair("ES256");
  const publicJwk = await exportJWK(publicKey); publicJwk.kid = "test-key"; publicJwk.alg = "ES256";
  const app = createApp(new MemoryRepository(), createSupabaseAuthenticator(projectUrl, createLocalJWKSet({ keys: [publicJwk] })));
  async function token(role: string, subject = alex) { return new SignJWT({ role }).setProtectedHeader({ alg: "ES256", kid: "test-key" }).setIssuer(issuer).setAudience("authenticated").setSubject(subject).setIssuedAt().setExpirationTime("5m").sign(privateKey); }
  const valid = await app.request("/v1/profile", { method: "PUT", headers: { authorization: `Bearer ${await token("authenticated")}`, "content-type": "application/json" }, body: JSON.stringify({ displayName: "Alex" }) }); assert.equal(valid.status, 200);
  const wrongRole = await app.request("/v1/profile", { method: "PUT", headers: { authorization: `Bearer ${await token("anon")}`, "content-type": "application/json" }, body: JSON.stringify({ displayName: "Alex" }) }); assert.equal(wrongRole.status, 401);
});
