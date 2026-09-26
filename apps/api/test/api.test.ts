import assert from "node:assert/strict";
import { test } from "node:test";
import { createApp } from "../src/app.js";
import { MemoryRepository } from "../src/memory-repository.js";

const alex = "00000000-0000-4000-8000-000000000001";
const jamie = "00000000-0000-4000-8000-000000000002";
const stranger = "00000000-0000-4000-8000-000000000003";

function request(app: ReturnType<typeof createApp>, path: string, userId: string, init: RequestInit = {}) {
  return app.request(path, { ...init, headers: { "x-user-id": userId, ...init.headers } });
}

async function jsonRequest(app: ReturnType<typeof createApp>, path: string, userId: string, method: string, body: unknown) {
  return request(app, path, userId, {
    method,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function setup() {
  const repository = new MemoryRepository();
  const app = createApp(repository, async (context) => context.req.header("x-user-id") ?? null);
  for (const [id, displayName] of [[alex, "Alex"], [jamie, "Jamie"], [stranger, "Stranger"]]) {
    assert.equal((await jsonRequest(app, "/v1/profile", id!, "PUT", { displayName })).status, 200);
  }
  const groupResponse = await jsonRequest(app, "/v1/groups", alex, "POST", { name: "Apartment", currency: "USD" });
  assert.equal(groupResponse.status, 201);
  const group = await groupResponse.json() as { id: string };
  assert.equal((await jsonRequest(app, `/v1/groups/${group.id}/members`, alex, "POST", { userId: jamie })).status, 204);
  return { app, groupId: group.id };
}

test("concurrent expenses produce an additive, zero-sum ledger", async () => {
  const { app, groupId } = await setup();
  const first = {
    clientRequestId: "10000000-0000-4000-8000-000000000001",
    description: "Groceries", transactionDate: "2026-09-18", payerId: alex, currency: "USD",
    items: [{ name: "Shared groceries", amountCents: 3000 }],
    allocations: [{ userId: alex, amountCents: 1000 }, { userId: jamie, amountCents: 2000 }],
  };
  const second = {
    clientRequestId: "10000000-0000-4000-8000-000000000002",
    description: "Supplies", transactionDate: "2026-09-19", payerId: jamie, currency: "USD",
    items: [{ name: "Cleaning supplies", amountCents: 2000 }],
    allocations: [{ userId: alex, amountCents: 1000 }, { userId: jamie, amountCents: 1000 }],
  };
  const [firstResponse, secondResponse] = await Promise.all([
    jsonRequest(app, `/v1/groups/${groupId}/expenses`, alex, "POST", first),
    jsonRequest(app, `/v1/groups/${groupId}/expenses`, jamie, "POST", second),
  ]);
  assert.equal(firstResponse.status, 201);
  assert.equal(secondResponse.status, 201);

  const snapshotResponse = await request(app, `/v1/groups/${groupId}/snapshot`, alex);
  assert.equal(snapshotResponse.status, 200);
  const snapshot = await snapshotResponse.json() as { group: { version: number }; expenses: unknown[]; balances: Record<string, number> };
  assert.equal(snapshot.group.version, 2);
  assert.equal(snapshot.expenses.length, 2);
  assert.deepEqual(snapshot.balances, { [alex]: 1000, [jamie]: -1000 });
  assert.equal(Object.values(snapshot.balances).reduce((sum, value) => sum + value, 0), 0);

  const payment = await jsonRequest(app, `/v1/groups/${groupId}/payments`, jamie, "POST", {
    clientRequestId: "10000000-0000-4000-8000-000000000003",
    fromUserId: jamie, toUserId: alex, amountCents: 1000, transactionDate: "2026-09-21",
  });
  assert.equal(payment.status, 201);
  const settled = await (await request(app, `/v1/groups/${groupId}/snapshot`, alex)).json() as {
    group: { version: number }; payments: unknown[]; balances: Record<string, number>;
  };
  assert.equal(settled.group.version, 3);
  assert.equal(settled.payments.length, 1);
  assert.deepEqual(settled.balances, { [alex]: 0, [jamie]: 0 });
});

test("idempotent retries return the original expense and reject changed payloads", async () => {
  const { app, groupId } = await setup();
  const expense = {
    clientRequestId: "20000000-0000-4000-8000-000000000001",
    description: "Dinner", transactionDate: "2026-09-20", payerId: alex, currency: "USD",
    items: [{ name: "Dinner", amountCents: 4000 }],
    allocations: [{ userId: alex, amountCents: 2000 }, { userId: jamie, amountCents: 2000 }],
  };
  const first = await jsonRequest(app, `/v1/groups/${groupId}/expenses`, alex, "POST", expense);
  const retry = await jsonRequest(app, `/v1/groups/${groupId}/expenses`, alex, "POST", expense);
  assert.equal(first.status, 201);
  assert.equal(retry.status, 201);
  assert.equal((await first.json() as { id: string }).id, (await retry.json() as { id: string }).id);

  const conflict = await jsonRequest(app, `/v1/groups/${groupId}/expenses`, alex, "POST", { ...expense, description: "Changed" });
  assert.equal(conflict.status, 409);
  const snapshot = await (await request(app, `/v1/groups/${groupId}/snapshot`, alex)).json() as { expenses: unknown[] };
  assert.equal(snapshot.expenses.length, 1);
});

test("database-style image endpoints preserve bytes and enforce group visibility", async () => {
  const { app, groupId } = await setup();
  const bytes = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
  const upload = await request(app, `/v1/groups/${groupId}/receipts`, alex, {
    method: "POST", headers: { "content-type": "image/jpeg" }, body: bytes,
  });
  assert.equal(upload.status, 201);
  const { id } = await upload.json() as { id: string };

  const visible = await request(app, `/v1/receipts/${id}/image`, jamie);
  assert.equal(visible.status, 200);
  assert.equal(visible.headers.get("content-type"), "image/jpeg");
  assert.deepEqual(new Uint8Array(await visible.arrayBuffer()), bytes);
  assert.equal((await request(app, `/v1/receipts/${id}/image`, stranger)).status, 403);

  const spoofed = await request(app, `/v1/groups/${groupId}/receipts`, alex, {
    method: "POST", headers: { "content-type": "image/png" }, body: bytes,
  });
  assert.equal(spoofed.status, 415);
});

test("invalid allocations and unauthorized snapshots are rejected", async () => {
  const { app, groupId } = await setup();
  const invalid = await jsonRequest(app, `/v1/groups/${groupId}/expenses`, alex, "POST", {
    clientRequestId: "30000000-0000-4000-8000-000000000001",
    description: "Mismatch", transactionDate: "2026-09-20", payerId: alex, currency: "USD",
    items: [{ name: "Item", amountCents: 1000 }],
    allocations: [{ userId: alex, amountCents: 999 }],
  });
  assert.equal(invalid.status, 422);
  assert.equal((await request(app, `/v1/groups/${groupId}/snapshot`, stranger)).status, 403);
});
