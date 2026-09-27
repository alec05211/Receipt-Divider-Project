import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import postgres from "postgres";
import { createApp } from "../src/app.ts";
import { PostgresRepository } from "../src/postgres-repository.ts";

const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) throw new Error("DATABASE_URL is required. Run this through npm run smoke:postgres.");

const ownerId = randomUUID();
const repository = new PostgresRepository(databaseUrl);
const cleanup = postgres(databaseUrl, { max: 1, prepare: false, ssl: "require", connect_timeout: 10 });
const app = createApp(repository, async (context) => context.req.header("x-user-id") ?? null);

function request(path: string, init: RequestInit = {}) {
  return app.request(path, { ...init, headers: { "x-user-id": ownerId, ...init.headers } });
}

function jsonRequest(path: string, method: string, body: unknown) {
  return request(path, { method, headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
}

async function requireStatus(response: Response, expected: number): Promise<void> {
  if (response.status !== expected) {
    throw new Error(`Expected HTTP ${expected}, received ${response.status}: ${await response.text()}`);
  }
}

try {
  const profile = await jsonRequest("/v1/profile", "PUT", {});
  await requireStatus(profile, 200);

  const selfResponse = await jsonRequest("/v1/people", "POST", { displayName: "Test Owner" });
  await requireStatus(selfResponse, 201);
  const selfPersonId = (await selfResponse.json() as { id: string }).id;

  const roommateResponse = await jsonRequest("/v1/people", "POST", { displayName: "Test Roommate" });
  await requireStatus(roommateResponse, 201);
  const roommatePersonId = (await roommateResponse.json() as { id: string }).id;

  const filterResponse = await jsonRequest("/v1/saved-filters", "POST", {
    name: "Test Roommates",
    personIds: [roommatePersonId],
  });
  await requireStatus(filterResponse, 201);
  const filterId = (await filterResponse.json() as { id: string }).id;

  const imageBytes = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
  const evidenceResponse = await request("/v1/evidence?kind=receipt", {
    method: "POST",
    headers: { "content-type": "image/jpeg" },
    body: imageBytes,
  });
  await requireStatus(evidenceResponse, 201);
  const evidenceId = (await evidenceResponse.json() as { id: string }).id;

  const expenseInput = {
    clientRequestId: randomUUID(),
    description: "Integration dinner",
    transactionDate: "2026-09-26",
    payerPersonId: selfPersonId,
    currency: "USD",
    totalCents: 2500,
    evidenceIds: [evidenceId],
    items: [{ name: "Shared dinner", amountCents: 2500 }],
    allocations: [
      { personId: selfPersonId, amountCents: 1000 },
      { personId: roommatePersonId, amountCents: 1500 },
    ],
  };
  const expenseResponse = await jsonRequest("/v1/expenses", "POST", expenseInput);
  await requireStatus(expenseResponse, 201);
  const expenseId = (await expenseResponse.json() as { id: string }).id;

  const retryResponse = await jsonRequest("/v1/expenses", "POST", expenseInput);
  await requireStatus(retryResponse, 201);
  assert.equal((await retryResponse.json() as { id: string }).id, expenseId);

  const snapshotResponse = await request(`/v1/transactions?filterId=${filterId}`);
  await requireStatus(snapshotResponse, 200);
  const snapshot = await snapshotResponse.json() as {
    version: number;
    appliedFilterId: string;
    expenses: Array<{ id: string }>;
    balances: Record<string, number>;
  };
  assert.equal(snapshot.version, 1);
  assert.equal(snapshot.appliedFilterId, filterId);
  assert.deepEqual(snapshot.expenses.map((expense) => expense.id), [expenseId]);
  assert.equal(snapshot.balances[selfPersonId], 1500);
  assert.equal(snapshot.balances[roommatePersonId], -1500);

  const imageResponse = await request(`/v1/evidence/${evidenceId}/image`);
  await requireStatus(imageResponse, 200);
  assert.deepEqual(new Uint8Array(await imageResponse.arrayBuffer()), imageBytes);

  console.log("Supabase PostgreSQL smoke test passed: profile, people, saved filter, evidence, expense, idempotency, and balances.");
} finally {
  await repository.close();
  await cleanup.begin(async (transaction) => {
    await transaction`DELETE FROM audit_events WHERE owner_id = ${ownerId}`;
    await transaction`DELETE FROM expense_evidence WHERE owner_id = ${ownerId}`;
    await transaction`DELETE FROM expense_allocations WHERE owner_id = ${ownerId}`;
    await transaction`DELETE FROM expense_items WHERE owner_id = ${ownerId}`;
    await transaction`DELETE FROM expenses WHERE owner_id = ${ownerId}`;
    await transaction`DELETE FROM repayments WHERE owner_id = ${ownerId}`;
    await transaction`DELETE FROM saved_filter_people WHERE owner_id = ${ownerId}`;
    await transaction`DELETE FROM saved_filters WHERE owner_id = ${ownerId}`;
    await transaction`DELETE FROM evidence_assets WHERE owner_id = ${ownerId}`;
    await transaction`DELETE FROM people WHERE owner_id = ${ownerId}`;
    await transaction`DELETE FROM ledgers WHERE owner_id = ${ownerId}`;
    await transaction`DELETE FROM user_profiles WHERE id = ${ownerId}`;
  });
  await cleanup.end();
}
