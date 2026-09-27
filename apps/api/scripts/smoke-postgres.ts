import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import postgres from "postgres";
import { createApp } from "../src/app.ts";
import { PostgresRepository } from "../src/postgres-repository.ts";

const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) throw new Error("DATABASE_URL is required. Run this through npm run smoke:postgres.");

const ownerId = randomUUID(), roommateId = randomUUID(), suffix = randomUUID().slice(0, 8);
const repository = new PostgresRepository(databaseUrl);
const cleanup = postgres(databaseUrl, { max: 1, prepare: false, ssl: "require", connect_timeout: 10 });
const app = createApp(repository, async (context) => context.req.header("x-user-id") ?? null);

function request(path: string, init: RequestInit = {}, userId = ownerId) {
  return app.request(path, { ...init, headers: { "x-user-id": userId, ...init.headers } });
}

function jsonRequest(path: string, method: string, body: unknown, userId = ownerId) {
  return request(path, { method, headers: { "content-type": "application/json" }, body: JSON.stringify(body) }, userId);
}

async function requireStatus(response: Response, expected: number): Promise<void> {
  if (response.status !== expected) {
    throw new Error(`Expected HTTP ${expected}, received ${response.status}: ${await response.text()}`);
  }
}

interface Snapshot { appliedFilterId?: string; people: Array<{ userId: string }>; expenses: Array<{ id: string; transactionDate: string; category: string | null }>; payments: unknown[]; balances: Record<string, number>; netBalance: number; }

try {
  for (const [userId, lastName] of [[ownerId, "Owner"], [roommateId, "Roommate"]] as const) {
    await requireStatus(await jsonRequest("/v1/profile", "PUT", {}, userId), 200);
    await requireStatus(await jsonRequest("/v1/profile/identity", "PUT", { firstName: "Test", lastName, username: `${lastName.toLowerCase()}_${suffix}` }, userId), 200);
  }
  const invite = await jsonRequest("/v1/friend-requests", "POST", { username: `roommate_${suffix}` });
  await requireStatus(invite, 201);
  const { requestId } = await invite.json() as { requestId: string };
  await requireStatus(await jsonRequest(`/v1/friend-requests/${requestId}/accept`, "POST", {}, roommateId), 200);

  const filterResponse = await jsonRequest("/v1/saved-filters", "POST", { name: "Test Roommates", userIds: [roommateId] });
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
    category: "restaurant",
    transactionDate: "2026-09-26",
    payerId: ownerId,
    currency: "USD",
    totalCents: 2500,
    evidenceIds: [evidenceId],
    items: [{ name: "Shared dinner", amountCents: 2500 }],
    allocations: [
      { userId: ownerId, amountCents: 1000 },
      { userId: roommateId, amountCents: 1500 },
    ],
  };
  const expenseResponse = await jsonRequest("/v1/expenses", "POST", expenseInput);
  await requireStatus(expenseResponse, 201);
  const expenseId = (await expenseResponse.json() as { id: string }).id;

  const retryResponse = await jsonRequest("/v1/expenses", "POST", expenseInput);
  await requireStatus(retryResponse, 201);
  assert.equal((await retryResponse.json() as { id: string }).id, expenseId);

  const filteredResponse = await request(`/v1/transactions?filterId=${filterId}`);
  await requireStatus(filteredResponse, 200);
  const filtered = await filteredResponse.json() as Snapshot;
  assert.equal(filtered.appliedFilterId, filterId);
  assert.deepEqual(filtered.expenses.map((expense) => expense.id), [expenseId]);
  assert.equal(filtered.expenses[0]!.transactionDate, "2026-09-26");
  assert.equal(filtered.expenses[0]!.category, "restaurant");
  assert.equal(filtered.balances[roommateId], 1500);
  assert.equal(filtered.netBalance, 1500);

  const roommateView = await (await request("/v1/transactions", {}, roommateId)).json() as Snapshot;
  assert.deepEqual(roommateView.expenses.map((expense) => expense.id), [expenseId]);
  assert.equal(roommateView.balances[ownerId], -1500);
  assert.ok(roommateView.people.some((person) => person.userId === ownerId));

  const imageResponse = await request(`/v1/evidence/${evidenceId}/image`, {}, roommateId);
  await requireStatus(imageResponse, 200);
  assert.deepEqual(new Uint8Array(await imageResponse.arrayBuffer()), imageBytes);

  await requireStatus(await jsonRequest("/v1/payments", "POST", { clientRequestId: randomUUID(), fromUserId: roommateId, toUserId: ownerId, amountCents: 1500, transactionDate: "2026-09-27" }, roommateId), 201);
  const settled = await (await request("/v1/transactions")).json() as Snapshot;
  assert.equal(settled.balances[roommateId], 0);
  assert.equal(settled.payments.length, 1);

  console.log("Supabase PostgreSQL smoke test passed: friends, saved filter, evidence, shared expense, idempotency, balances, and repayment.");
} finally {
  await repository.close();
  const users = [ownerId, roommateId];
  await cleanup.begin(async (transaction) => {
    await transaction`DELETE FROM audit_events WHERE actor_id IN ${transaction(users)}`;
    await transaction`DELETE FROM expenses WHERE creator_id IN ${transaction(users)}`;
    await transaction`DELETE FROM repayments WHERE recorder_id IN ${transaction(users)}`;
    await transaction`DELETE FROM evidence_assets WHERE uploaded_by IN ${transaction(users)}`;
    await transaction`DELETE FROM user_profiles WHERE id IN ${transaction(users)}`;
  });
  await cleanup.end();
}
