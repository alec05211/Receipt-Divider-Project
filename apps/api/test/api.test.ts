import assert from "node:assert/strict";
import { test } from "node:test";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from "jose";
import { createApp } from "../src/app.ts";
import { MemoryRepository } from "../src/memory-repository.ts";
import { createSupabaseAuthenticator } from "../src/supabase-auth.ts";

const alex = "00000000-0000-4000-8000-000000000001";
const jamie = "00000000-0000-4000-8000-000000000002";
const stranger = "00000000-0000-4000-8000-000000000003";
const morgan = "00000000-0000-4000-8000-000000000004";

function request(app: ReturnType<typeof createApp>, path: string, userId: string, init: RequestInit = {}) { return app.request(path, { ...init, headers: { "x-user-id": userId, ...init.headers } }); }
async function jsonRequest(app: ReturnType<typeof createApp>, path: string, userId: string, method: string, body: unknown) { return request(app, path, userId, { method, headers: { "content-type": "application/json" }, body: JSON.stringify(body) }); }

async function setup(developerIds = new Set<string>()) {
  const app = createApp(new MemoryRepository(developerIds), async (context) => context.req.header("x-user-id") ?? null);
  for (const user of [alex, jamie, stranger, morgan]) assert.equal((await request(app, "/v1/profile", user, { method: "PUT" })).status, 200);
  return { app };
}

/** Alex is friends with Jamie and Morgan; the stranger is nobody's friend. */
async function setupFriends(developerIds?: Set<string>) {
  const { app } = await setup(developerIds);
  const names: Array<[string, string, string]> = [[alex, "Alex", "alex"], [jamie, "Jamie", "jamie"], [stranger, "Sam", "stranger"], [morgan, "Morgan", "morgan"]];
  for (const [user, firstName, username] of names) assert.equal((await jsonRequest(app, "/v1/profile/identity", user, "PUT", { firstName, lastName: "Test", username })).status, 200);
  for (const [friend, username] of [[jamie, "jamie"], [morgan, "morgan"]] as const) {
    const invite = await jsonRequest(app, "/v1/friend-requests", alex, "POST", { username }); assert.equal(invite.status, 201);
    const { requestId } = await invite.json() as { requestId: string };
    assert.equal((await jsonRequest(app, `/v1/friend-requests/${requestId}/accept`, friend, "POST", {})).status, 200);
  }
  return { app };
}

interface Snapshot { people: Array<{ userId: string }>; expenses: Array<{ id: string; description: string; payerId: string }>; payments: unknown[]; balances: Record<string, number>; netBalance: number; appliedFilterId?: string; }
async function snapshot(app: ReturnType<typeof createApp>, user: string, query = "") { return await (await request(app, `/v1/transactions${query}`, user)).json() as Snapshot; }
function expense(clientRequestId: string, payerId: string, allocations: Array<[string, number]>, extra: Record<string, unknown> = {}) {
  const totalCents = allocations.reduce((sum, [, cents]) => sum + cents, 0);
  return { clientRequestId, description: "Groceries", transactionDate: "2026-09-18", payerId, currency: "USD", totalCents, allocations: allocations.map(([userId, amountCents]) => ({ userId, amountCents })), ...extra };
}

test("an expense is shared with everyone on it, and balances mirror each other", async () => {
  const { app } = await setupFriends();
  assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", expense("10000000-0000-4000-8000-000000000001", alex, [[alex, 1000], [jamie, 2000]]))).status, 201);
  let mine = await snapshot(app, alex), theirs = await snapshot(app, jamie);
  assert.equal(mine.expenses.length, 1); assert.equal(theirs.expenses.length, 1);
  assert.equal(mine.balances[jamie], 2000); assert.equal(theirs.balances[alex], -2000);
  assert.equal(mine.netBalance, 2000); assert.equal(theirs.netBalance, -2000);
  assert.ok(theirs.people.some((person) => person.userId === alex));
  assert.equal((await snapshot(app, stranger)).expenses.length, 0);
  assert.equal((await snapshot(app, morgan)).expenses.length, 0);

  // Jamie records paying Alex back; it settles both sides.
  assert.equal((await jsonRequest(app, "/v1/payments", jamie, "POST", { clientRequestId: "10000000-0000-4000-8000-000000000002", fromUserId: jamie, toUserId: alex, amountCents: 2000, transactionDate: "2026-09-21" })).status, 201);
  mine = await snapshot(app, alex); theirs = await snapshot(app, jamie);
  assert.equal(mine.balances[jamie], 0); assert.equal(theirs.balances[alex], 0); assert.equal(mine.payments.length, 1);
});

test("in a group expense everyone owes only the payer", async () => {
  const { app } = await setupFriends();
  assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", expense("11000000-0000-4000-8000-000000000001", alex, [[alex, 1000], [jamie, 1000], [morgan, 1000]]))).status, 201);
  const jamieView = await snapshot(app, jamie);
  assert.equal(jamieView.balances[alex], -1000); assert.equal(jamieView.balances[morgan] ?? 0, 0);
  assert.equal((await snapshot(app, alex)).netBalance, 2000);
});

test("you can only split with yourself and your friends", async () => {
  const { app } = await setupFriends();
  assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", expense("12000000-0000-4000-8000-000000000001", alex, [[stranger, 1000]]))).status, 422);
  assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", expense("12000000-0000-4000-8000-000000000002", stranger, [[alex, 1000]]))).status, 422);
  // Jamie and Morgan are both Alex's friends but not each other's.
  assert.equal((await jsonRequest(app, "/v1/expenses", jamie, "POST", expense("12000000-0000-4000-8000-000000000003", jamie, [[morgan, 1000]]))).status, 422);
  assert.equal((await jsonRequest(app, "/v1/payments", alex, "POST", { clientRequestId: "12000000-0000-4000-8000-000000000004", fromUserId: stranger, toUserId: alex, amountCents: 100, transactionDate: "2026-09-21" })).status, 422);
  assert.equal((await jsonRequest(app, "/v1/payments", alex, "POST", { clientRequestId: "12000000-0000-4000-8000-000000000005", fromUserId: jamie, toUserId: morgan, amountCents: 100, transactionDate: "2026-09-21" })).status, 422);
});

test("IDs are matched regardless of case, since Swift sends UUIDs in uppercase", async () => {
  const app = createApp(new MemoryRepository(), async (context) => context.req.header("x-user-id") ?? null);
  const ben = "d139b19d-e1f9-420e-ac59-079893a37044", luke = "fbbde5da-ce1e-45e9-a286-05ee860209bb";
  for (const [user, username] of [[ben, "ben"], [luke, "luke"]] as const) {
    assert.equal((await request(app, "/v1/profile", user, { method: "PUT" })).status, 200);
    assert.equal((await jsonRequest(app, "/v1/profile/identity", user, "PUT", { firstName: username, lastName: "Test", username })).status, 200);
  }
  const invite = await jsonRequest(app, "/v1/friend-requests", ben, "POST", { username: "luke" });
  const { requestId } = await invite.json() as { requestId: string };
  assert.equal((await jsonRequest(app, `/v1/friend-requests/${requestId}/accept`, luke, "POST", {})).status, 200);
  const up = (id: string) => id.toUpperCase();
  assert.equal((await jsonRequest(app, "/v1/expenses", ben, "POST", expense(up("13000000-0000-4000-8000-00000000000a"), up(ben), [[up(ben), 1000], [up(luke), 1000]]))).status, 201);
  assert.equal((await jsonRequest(app, "/v1/payments", luke, "POST", { clientRequestId: up("13000000-0000-4000-8000-00000000000b"), fromUserId: up(luke), toUserId: up(ben), amountCents: 1000, transactionDate: "2026-09-21" })).status, 201);
  assert.equal((await snapshot(app, ben)).balances[luke] ?? 0, 0);
});

test("removing a friend keeps shared history and still allows settling up", async () => {
  const { app } = await setupFriends();
  assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", expense("13000000-0000-4000-8000-000000000001", alex, [[jamie, 1500]]))).status, 201);
  assert.equal((await request(app, `/v1/friends/${jamie}`, alex, { method: "DELETE" })).status, 204);
  assert.equal((await (await request(app, "/v1/friends", jamie)).json() as unknown[]).length, 0);
  assert.equal((await snapshot(app, jamie)).balances[alex], -1500);
  assert.equal((await jsonRequest(app, "/v1/payments", jamie, "POST", { clientRequestId: "13000000-0000-4000-8000-000000000002", fromUserId: jamie, toUserId: alex, amountCents: 1500, transactionDate: "2026-09-21" })).status, 201);
  assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", expense("13000000-0000-4000-8000-000000000003", alex, [[jamie, 100]]))).status, 422);
});

test("saved groups are personal any-person filters that never change balances", async () => {
  const { app } = await setupFriends();
  const filterResponse = await jsonRequest(app, "/v1/saved-filters", alex, "POST", { name: "Roommates", userIds: [jamie] });
  assert.equal(filterResponse.status, 201); const filterId = (await filterResponse.json() as { id: string }).id;
  const expenses: Array<[string, string]> = [["20000000-0000-4000-8000-000000000001", jamie], ["20000000-0000-4000-8000-000000000002", morgan], ["20000000-0000-4000-8000-000000000003", alex]];
  for (const [clientRequestId, participant] of expenses) assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", expense(clientRequestId, alex, [[participant, 1000]]))).status, 201);
  const all = await snapshot(app, alex), filtered = await snapshot(app, alex, `?filterId=${filterId}`);
  assert.equal(all.expenses.length, 3); assert.equal(filtered.appliedFilterId, filterId); assert.equal(filtered.expenses.length, 1); assert.deepEqual(filtered.balances, all.balances);
  assert.equal((await request(app, `/v1/transactions?filterId=${filterId}`, jamie)).status, 404);
  assert.equal((await jsonRequest(app, "/v1/saved-filters", alex, "POST", { name: "Strangers", userIds: [stranger] })).status, 422);
});

test("receipt evidence is visible to everyone on the expense and nobody else", async () => {
  const { app } = await setupFriends(); const bytes = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
  const upload = await request(app, "/v1/evidence?kind=ticket_confirmation", alex, { method: "POST", headers: { "content-type": "image/jpeg" }, body: bytes });
  assert.equal(upload.status, 201); const { id } = await upload.json() as { id: string };
  assert.equal((await request(app, `/v1/evidence/${id}/image`, jamie)).status, 404);
  const created = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("30000000-0000-4000-8000-000000000001", alex, [[jamie, 5000]], { evidenceIds: [id] }));
  assert.equal(created.status, 201); assert.deepEqual((await created.json() as { evidenceIds: string[] }).evidenceIds, [id]);
  for (const user of [alex, jamie]) assert.deepEqual(new Uint8Array(await (await request(app, `/v1/evidence/${id}/image`, user)).arrayBuffer()), bytes);
  assert.equal((await request(app, `/v1/evidence/${id}/image`, stranger)).status, 404);
  assert.equal((await jsonRequest(app, "/v1/expenses", jamie, "POST", expense("30000000-0000-4000-8000-000000000002", jamie, [[alex, 100]], { evidenceIds: [id] }))).status, 400);
  assert.equal((await request(app, "/v1/evidence?kind=receipt", alex, { method: "POST", headers: { "content-type": "image/png" }, body: bytes })).status, 415);
});

test("several expenses can be split from one uploaded receipt", async () => {
  const { app } = await setupFriends(); const bytes = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 5, 6, 7, 8]);
  const upload = await request(app, "/v1/evidence?kind=receipt", alex, { method: "POST", headers: { "content-type": "image/jpeg" }, body: bytes });
  const { id } = await upload.json() as { id: string };
  const withJamie = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("31000000-0000-4000-8000-000000000001", alex, [[alex, 300], [jamie, 300]], { evidenceIds: [id], items: [{ name: "Bread", amountCents: 600 }] }));
  const withMorgan = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("31000000-0000-4000-8000-000000000002", alex, [[morgan, 450]], { evidenceIds: [id], items: [{ name: "Coffee", amountCents: 450 }] }));
  assert.equal(withJamie.status, 201); assert.equal(withMorgan.status, 201);
  // Both expenses point at the one receipt, so the app can group them.
  const expenses = (await snapshot(app, alex)).expenses as unknown as Array<{ evidenceIds: string[] }>;
  assert.deepEqual(expenses.map((e) => e.evidenceIds), [[id], [id]]);
  // Each person sees only their own expense, but the receipt through it; a stranger sees neither.
  assert.equal((await snapshot(app, jamie)).expenses.length, 1); assert.equal((await snapshot(app, morgan)).expenses.length, 1);
  for (const user of [alex, jamie, morgan]) assert.equal((await request(app, `/v1/evidence/${id}/image`, user)).status, 200);
  assert.equal((await request(app, `/v1/evidence/${id}/image`, stranger)).status, 404);
});

test("only the uploader can store the text recognized in their receipt", async () => {
  const { app } = await setupFriends(); const bytes = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
  const upload = await request(app, "/v1/evidence?kind=receipt", alex, { method: "POST", headers: { "content-type": "image/jpeg" }, body: bytes });
  const { id } = await upload.json() as { id: string };
  assert.equal((await jsonRequest(app, `/v1/evidence/${id}/text`, alex, "PUT", { text: "TRADER JOE'S\n09/27/26 5:41 PM" })).status, 204);
  assert.equal((await jsonRequest(app, `/v1/evidence/${id}/text`, jamie, "PUT", { text: "not mine" })).status, 404);
  assert.equal((await jsonRequest(app, `/v1/evidence/${id}/text`, alex, "PUT", { text: 42 })).status, 400);
  assert.equal((await jsonRequest(app, `/v1/evidence/${id}/text`, alex, "PUT", { text: "TRADER JOE'S", diagnostics: { reader: "model", attempts: [] } })).status, 204);
  assert.equal((await jsonRequest(app, `/v1/evidence/${id}/text`, alex, "PUT", { text: "TRADER JOE'S", diagnostics: ["not", "an", "object"] })).status, 400);
  assert.equal((await jsonRequest(app, `/v1/evidence/${id}/text`, alex, "PUT", { text: "TRADER JOE'S", diagnostics: { lines: "x".repeat(500_001) } })).status, 400);
  assert.equal((await jsonRequest(app, `/v1/evidence/${id}/text`, alex, "PUT", { text: "x".repeat(100_001) })).status, 400);
});

test("idempotency and exact totals protect canonical expenses", async () => {
  const { app } = await setupFriends();
  const input = expense("40000000-0000-4000-8000-000000000001", alex, [[alex, 2000], [jamie, 2000]], { items: [{ name: "Dinner", amountCents: 4000 }] });
  const first = await jsonRequest(app, "/v1/expenses", alex, "POST", input), retry = await jsonRequest(app, "/v1/expenses", alex, "POST", input);
  assert.equal((await first.json() as { id: string }).id, (await retry.json() as { id: string }).id);
  assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", { ...input, description: "Changed" })).status, 409);
  assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", { ...input, clientRequestId: "40000000-0000-4000-8000-000000000002", totalCents: 3999 })).status, 422);
});

test("items record who had them while allocations set what each person owes", async () => {
  const { app } = await setupFriends();
  type Item = { name: string; amountCents: number; ownerIds: string[] };
  // Three people share the juice; the slider then moves most of it onto Jamie.
  const juice = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("42000000-0000-4000-8000-000000000001", alex, [[alex, 50], [jamie, 200], [morgan, 50]], {
    items: [{ name: "Orange juice", amountCents: 300, ownerIds: [alex, jamie.toUpperCase(), morgan] }],
  }));
  assert.equal(juice.status, 201);
  assert.deepEqual((await juice.json() as { items: Item[] }).items, [{ name: "Orange juice", amountCents: 300, localOffsetCents: 0, globalOffsetCents: 0, kind: "item", taxed: true, ownerIds: [alex, jamie, morgan] }]);

  // An unowned item belongs to the payer, and an expense without items becomes one item owned by everyone on it.
  const unowned = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("42000000-0000-4000-8000-000000000002", jamie, [[alex, 100], [jamie, 100]], {
    items: [{ name: "Bread", amountCents: 100, ownerIds: [alex] }, { name: "Milk", amountCents: 100 }],
  }));
  assert.deepEqual((await unowned.json() as { items: Item[] }).items.map((item) => item.ownerIds), [[alex], [jamie]]);
  const whole = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("42000000-0000-4000-8000-000000000003", alex, [[alex, 600], [jamie, 600]], { description: "Movie" }));
  assert.deepEqual((await whole.json() as { items: Item[] }).items, [{ name: "Movie", amountCents: 1200, localOffsetCents: 0, globalOffsetCents: 0, kind: "item", taxed: true, ownerIds: [alex, jamie] }]);

  const shared = (await snapshot(app, jamie)).expenses as unknown as Array<{ items: Item[] }>;
  assert.ok(shared.some((entry) => entry.items[0]?.name === "Orange juice" && entry.items[0].ownerIds.length === 3));

  // Owners must be on the expense, listed once.
  for (const ownerIds of [[stranger], [alex, alex], ["not-a-uuid"]]) {
    const status = (await jsonRequest(app, "/v1/expenses", alex, "POST", expense("42000000-0000-4000-8000-000000000004", alex, [[alex, 300]], { items: [{ name: "Juice", amountCents: 300, ownerIds }] }))).status;
    assert.ok(status === 400 || status === 422, `${ownerIds} gave ${status}`);
  }
  // Items need not add up to the total, as when an evenly split receipt uses its printed total.
  const printed = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("42000000-0000-4000-8000-000000000006", alex, [[alex, 550], [jamie, 550]], { items: [{ name: "Pasta", amountCents: 900, ownerIds: [alex, jamie] }] }));
  assert.equal(printed.status, 201);
  assert.equal((await printed.json() as { totalCents: number }).totalCents, 1100);

  // The payer may own items without owing anything.
  const treat = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("42000000-0000-4000-8000-000000000005", alex, [[jamie, 300]], { items: [{ name: "Juice", amountCents: 300 }] }));
  assert.deepEqual((await treat.json() as { items: Item[] }).items[0]!.ownerIds, [alex]);
});

test("items keep their printed price with local and global offsets, and adjustments keep receipt order", async () => {
  const { app } = await setupFriends();
  // A $10 burger with a $1 coupon and a $5 untaxed salad, 6% tax on the burger, a $4 tip, then a 3% card surcharge.
  const adjustments = [{ kind: "tax", amountCents: 54, rate: 0.06 }, { kind: "tip", amountCents: 400, rate: null }, { kind: "surcharge", amountCents: 44, rate: 0.03 }];
  const meal = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("43000000-0000-4000-8000-000000000001", alex, [[alex, 1000], [jamie, 998]], {
    items: [
      { name: "Burger", amountCents: 1000, localOffsetCents: -100, globalOffsetCents: 82, ownerIds: [alex] },
      { name: "Salad", amountCents: 500, globalOffsetCents: 15, taxed: false, ownerIds: [jamie] },
      { name: "Tip", amountCents: 400, globalOffsetCents: 1, kind: "tip", ownerIds: [alex, jamie] },
    ],
    adjustments,
  }));
  assert.equal(meal.status, 201);
  const saved = await meal.json() as { items: Array<Record<string, unknown>>; adjustments: unknown };
  assert.deepEqual(saved.items.map(({ localOffsetCents, globalOffsetCents, kind, taxed }) => ({ localOffsetCents, globalOffsetCents, kind, taxed })), [
    { localOffsetCents: -100, globalOffsetCents: 82, kind: "item", taxed: true },
    { localOffsetCents: 0, globalOffsetCents: 15, kind: "item", taxed: false },
    { localOffsetCents: 0, globalOffsetCents: 1, kind: "tip", taxed: true },
  ]);
  assert.deepEqual(saved.adjustments, adjustments);
  const shared = (await snapshot(app, jamie)).expenses as unknown as Array<{ clientRequestId: string; adjustments: unknown }>;
  assert.deepEqual(shared.find((entry) => entry.clientRequestId === "43000000-0000-4000-8000-000000000001")?.adjustments, adjustments);

  // Older clients send one offset, which becomes the global offset; an expense without adjustments has none.
  const legacy = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("43000000-0000-4000-8000-000000000002", alex, [[alex, 1080]], { items: [{ name: "Wine", amountCents: 1000, offsetCents: 80 }] }));
  const legacyExpense = await legacy.json() as { items: Array<{ localOffsetCents: number; globalOffsetCents: number }>; adjustments: unknown[] };
  assert.deepEqual([legacyExpense.items[0]!.localOffsetCents, legacyExpense.items[0]!.globalOffsetCents], [0, 80]);
  assert.deepEqual(legacyExpense.adjustments, []);

  for (const extra of [
    { items: [{ name: "Tip", amountCents: 100, kind: "gift" }] },
    { items: [{ name: "Tip", amountCents: 100, taxed: "yes" }] },
    { adjustments: [{ kind: "fee", amountCents: 100, rate: null }] },
    { adjustments: [{ kind: "tax", amountCents: -1, rate: 0.06 }] },
    { adjustments: [{ kind: "tax", amountCents: 6, rate: -0.06 }] },
  ]) {
    const status = (await jsonRequest(app, "/v1/expenses", alex, "POST", expense("43000000-0000-4000-8000-000000000003", alex, [[alex, 100]], extra))).status;
    assert.equal(status, 400, JSON.stringify(extra));
  }
});

test("an expense may carry one of the known categories", async () => {
  const { app } = await setupFriends();
  const created = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("41000000-0000-4000-8000-000000000001", alex, [[alex, 1000], [jamie, 1000]], { category: "concert" }));
  assert.equal(created.status, 201);
  assert.equal((await created.json() as { category: string | null }).category, "concert");
  const plain = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("41000000-0000-4000-8000-000000000002", alex, [[alex, 1000]]));
  assert.equal((await plain.json() as { category: string | null }).category, null);
  const explicitNull = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("41000000-0000-4000-8000-000000000003", alex, [[alex, 1000]], { category: null }));
  assert.equal(explicitNull.status, 201);
  for (const category of ["Concert", "travel", 3]) {
    assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", expense("41000000-0000-4000-8000-000000000004", alex, [[alex, 1000]], { category }))).status, 400);
  }
  const shared = (await snapshot(app, jamie)).expenses as Array<{ description: string; category?: string | null }>;
  assert.deepEqual(shared.map((item) => item.category), ["concert"]);
});

test("only the payer can edit an expense's name and date, and each change is recorded as a revision", async () => {
  const repository = new MemoryRepository();
  const app = createApp(repository, async (context) => context.req.header("x-user-id") ?? null);
  for (const user of [alex, jamie, stranger, morgan]) assert.equal((await request(app, "/v1/profile", user, { method: "PUT" })).status, 200);
  for (const [user, username] of [[alex, "alex"], [jamie, "jamie"], [stranger, "stranger"]] as const) assert.equal((await jsonRequest(app, "/v1/profile/identity", user, "PUT", { firstName: username, lastName: "Test", username })).status, 200);
  const invite = await jsonRequest(app, "/v1/friend-requests", alex, "POST", { username: "jamie" });
  assert.equal((await jsonRequest(app, `/v1/friend-requests/${(await invite.json() as { requestId: string }).requestId}/accept`, jamie, "POST", {})).status, 200);
  // Alex creates it, but Jamie paid, so Jamie owns it.
  const created = await jsonRequest(app, "/v1/expenses", alex, "POST", expense("50000000-0000-4000-8000-000000000001", jamie, [[alex, 1000], [jamie, 1000]]));
  const { id } = await created.json() as { id: string };
  const before = await snapshot(app, alex);

  // The creator, who also has a share, can't edit it; nothing changes.
  for (const body of [{ description: "Mine now" }, { transactionDate: "2026-09-01" }]) assert.equal((await jsonRequest(app, `/v1/expenses/${id}`, alex, "PATCH", body)).status, 403);
  assert.equal(repository.auditEvents.length, 0);

  // The payer renames it (trimmed) and moves its date in one request: one revision per field, and everyone sees both.
  const edited = await jsonRequest(app, `/v1/expenses/${id.toUpperCase()}`, jamie, "PATCH", { description: "  Farmers market ", transactionDate: "2026-09-10" });
  assert.equal(edited.status, 200);
  const body = await edited.json() as { description: string; transactionDate: string };
  assert.equal(body.description, "Farmers market"); assert.equal(body.transactionDate, "2026-09-10");
  for (const user of [alex, jamie]) {
    const { expenses } = await snapshot(app, user) as unknown as { expenses: Array<{ description: string; transactionDate: string }> };
    assert.equal(expenses[0]!.description, "Farmers market"); assert.equal(expenses[0]!.transactionDate, "2026-09-10");
  }
  assert.deepEqual(repository.auditEvents, [
    { actorId: jamie, eventType: "expense.description_changed", entityId: id, details: { from: "Groceries", to: "Farmers market" } },
    { actorId: jamie, eventType: "expense.date_changed", entityId: id, details: { from: "2026-09-18", to: "2026-09-10" } },
  ]);
  // Editing doesn't touch amounts, so balances are unchanged.
  const after = await snapshot(app, alex);
  assert.deepEqual(after.balances, before.balances); assert.equal(after.netBalance, before.netBalance);

  // A date alone is recorded alone; unchanged values record nothing.
  assert.equal((await jsonRequest(app, `/v1/expenses/${id}`, jamie, "PATCH", { transactionDate: "2026-09-11" })).status, 200);
  assert.equal(repository.auditEvents.length, 3); assert.equal(repository.auditEvents[2]!.eventType, "expense.date_changed");
  assert.equal((await jsonRequest(app, `/v1/expenses/${id}`, jamie, "PATCH", { description: "Farmers market", transactionDate: "2026-09-11" })).status, 200);
  assert.equal(repository.auditEvents.length, 3);

  // Invalid or empty edits are rejected; outsiders and unknown expenses see nothing.
  for (const body of [{ description: "   " }, { description: "x".repeat(201) }, { description: 5 }, { transactionDate: "09/11/2026" }, { transactionDate: "2026-13-01" }, {}]) {
    assert.equal((await jsonRequest(app, `/v1/expenses/${id}`, jamie, "PATCH", body)).status, 400);
  }
  assert.equal((await jsonRequest(app, `/v1/expenses/${id}`, stranger, "PATCH", { description: "Mine now" })).status, 404);
  assert.equal((await jsonRequest(app, "/v1/expenses/50000000-0000-4000-8000-000000000009", jamie, "PATCH", { description: "Nothing" })).status, 404);
  assert.equal((await snapshot(app, alex)).expenses[0]!.description, "Farmers market");
});

test("display name is derived from first and last name", async () => {
  const { app } = await setup();
  let profile = await (await request(app, "/v1/profile", alex)).json() as { displayName: string | null; username: string | null };
  assert.equal(profile.displayName, null); assert.equal(profile.username, null);
  assert.equal((await jsonRequest(app, "/v1/profile/identity", alex, "PUT", { firstName: " Alex ", lastName: "Rivera", username: "Alex_R" })).status, 200);
  profile = await (await request(app, "/v1/profile", alex)).json() as { displayName: string | null; username: string | null };
  assert.equal(profile.displayName, "Alex Rivera"); assert.equal(profile.username, "alex_r");
});

test("user search matches first name, last name, and username prefixes", async () => {
  const { app } = await setup();
  assert.equal((await jsonRequest(app, "/v1/profile/identity", alex, "PUT", { firstName: "Alex", lastName: "Rivera", username: "arivera" })).status, 200);
  assert.equal((await jsonRequest(app, "/v1/profile/identity", stranger, "PUT", { firstName: "Sam", lastName: "Stone", username: "rocky" })).status, 200);
  async function search(query: string) { return await (await request(app, `/v1/users/search?q=${encodeURIComponent(query)}`, alex)).json() as Array<{ username: string; relationship: string }>; }
  assert.deepEqual((await search("sa")).map((user) => user.username), ["rocky"]);
  assert.deepEqual((await search("STO")).map((user) => user.username), ["rocky"]);
  assert.deepEqual((await search("rock")).map((user) => user.relationship), ["none"]);
  assert.deepEqual(await search("ar"), []);
  assert.equal((await request(app, "/v1/users/search?q=s", alex)).status, 400);
});

test("search results carry an avatar etag that changes when the photo does", async () => {
  const { app } = await setup();
  assert.equal((await jsonRequest(app, "/v1/profile/identity", stranger, "PUT", { firstName: "Sam", lastName: "Stone", username: "rocky" })).status, 200);
  async function etag() { return (await (await request(app, "/v1/users/search?q=rock", alex)).json() as Array<{ avatarEtag: string | null }>)[0]!.avatarEtag; }
  assert.equal(await etag(), null);
  async function upload(bytes: number[]) { return (await (await request(app, "/v1/profile/avatar", stranger, { method: "PUT", headers: { "content-type": "image/jpeg" }, body: Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, ...bytes]) })).json() as { etag: string }).etag; }
  const first = await upload([1]); assert.equal(await etag(), first);
  const second = await upload([2]); assert.notEqual(second, first); assert.equal(await etag(), second);
});

test("removing someone who isn't a friend is a 404", async () => {
  const { app } = await setup();
  assert.equal((await request(app, `/v1/friends/${stranger}`, alex, { method: "DELETE" })).status, 404);
  assert.equal((await request(app, "/v1/friends/not-a-uuid", alex, { method: "DELETE" })).status, 400);
});

test("settings start at USD, percent and an even tip, and can be changed", async () => {
  const { app } = await setup();
  assert.deepEqual(await (await request(app, "/v1/settings", alex)).json(), { currency: "USD", sliderUnit: "percent", tipSplit: "even" });
  const changed = await jsonRequest(app, "/v1/settings", alex, "PATCH", { sliderUnit: "dollars" });
  assert.equal(changed.status, 200); assert.deepEqual(await changed.json(), { currency: "USD", sliderUnit: "dollars", tipSplit: "even" });
  assert.equal(((await (await request(app, "/v1/settings", alex)).json()) as { sliderUnit: string }).sliderUnit, "dollars");
  assert.equal(((await (await request(app, "/v1/settings", jamie)).json()) as { sliderUnit: string }).sliderUnit, "percent");
  assert.equal((await jsonRequest(app, "/v1/settings", alex, "PATCH", { sliderUnit: "euros" })).status, 400);
  const tip = await (await jsonRequest(app, "/v1/settings", alex, "PATCH", { tipSplit: "proportional" })).json() as { sliderUnit: string; tipSplit: string };
  assert.deepEqual([tip.sliderUnit, tip.tipSplit], ["dollars", "proportional"]);
  assert.equal((await jsonRequest(app, "/v1/settings", alex, "PATCH", { tipSplit: "randomly" })).status, 400);
});

test("a developer can reset every expense and payment while accounts and friendships stay", async () => {
  const { app } = await setupFriends(new Set([alex]));
  assert.equal((await jsonRequest(app, "/v1/expenses", jamie, "POST", expense("10000000-0000-4000-8000-000000000041", jamie, [[alex, 500], [jamie, 500]]))).status, 201);
  assert.equal((await jsonRequest(app, "/v1/payments", alex, "POST", { clientRequestId: "10000000-0000-4000-8000-000000000042", fromUserId: alex, toUserId: jamie, amountCents: 500, transactionDate: "2026-09-21" })).status, 201);
  assert.equal((await (await request(app, "/v1/profile", alex)).json() as { isDeveloper: boolean }).isDeveloper, true);
  assert.equal((await (await request(app, "/v1/profile", jamie)).json() as { isDeveloper: boolean }).isDeveloper, false);

  // Only a developer may reset, and only with the exact confirmation.
  assert.equal((await jsonRequest(app, "/v1/developer/reset-ledger", jamie, "POST", { confirm: "DELETE" })).status, 403);
  assert.equal((await jsonRequest(app, "/v1/developer/reset-ledger", alex, "POST", { confirm: "delete" })).status, 400);
  assert.equal((await jsonRequest(app, "/v1/developer/reset-ledger", alex, "POST", {})).status, 400);
  assert.equal((await snapshot(app, jamie)).expenses.length, 1);

  assert.equal((await jsonRequest(app, "/v1/developer/reset-ledger", alex, "POST", { confirm: "DELETE" })).status, 204);
  for (const user of [alex, jamie]) {
    const after = await snapshot(app, user);
    assert.equal(after.expenses.length, 0); assert.equal(after.payments.length, 0); assert.equal(after.netBalance, 0);
  }
  const friends = await (await request(app, "/v1/friends", alex)).json() as unknown[];
  assert.equal(friends.length, 2);
  assert.equal((await (await request(app, "/v1/profile", jamie)).json() as { username: string }).username, "jamie");
});

test("Supabase JWT authentication accepts only signed authenticated-user tokens", async () => {
  const projectUrl = "https://receipt-divider.supabase.co", issuer = `${projectUrl}/auth/v1`, { publicKey, privateKey } = await generateKeyPair("ES256");
  const publicJwk = await exportJWK(publicKey); publicJwk.kid = "test-key"; publicJwk.alg = "ES256";
  const app = createApp(new MemoryRepository(), createSupabaseAuthenticator(projectUrl, createLocalJWKSet({ keys: [publicJwk] })));
  async function token(role: string, subject = alex) { return new SignJWT({ role }).setProtectedHeader({ alg: "ES256", kid: "test-key" }).setIssuer(issuer).setAudience("authenticated").setSubject(subject).setIssuedAt().setExpirationTime("5m").sign(privateKey); }
  const valid = await app.request("/v1/profile", { method: "PUT", headers: { authorization: `Bearer ${await token("authenticated")}`} }); assert.equal(valid.status, 200);
  const wrongRole = await app.request("/v1/profile", { method: "PUT", headers: { authorization: `Bearer ${await token("anon")}`} }); assert.equal(wrongRole.status, 401);
});

test("receipt vision parser returns the receipt's labeled rows", async () => {
  const { createOpenAIReceiptParser } = await import("../src/receipt-vision.ts");
  const bodies: any[] = [];
  const parser = createOpenAIReceiptParser({
    apiKey: "test-openai-key",
    fetchFn: async (_url, init) => {
      bodies.push(JSON.parse(init?.body as string));
      return new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify({
        merchant: "Trader Joe's", category: "groceries", purchaseDate: "2026-10-06", expenseName: "Trader Joe's Groceries",
        rows: [
          { text: "TRADER JOE'S", price: "", kind: "other", taxed: true },
          { text: "BANANAS", price: "2.49", kind: "item", taxed: false, name: "Bananas" },
          { text: "TOTAL", price: "2.49", kind: "total", taxed: true },
          { text: "MYSTERY", price: "1.00", kind: "invented", taxed: true },
        ],
      }) } }] }), { status: 200, headers: { "Content-Type": "application/json" } });
    },
  });
  const jpegBytes = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]);

  const result = await parser.parseReceipt("image/jpeg", jpegBytes);
  assert.equal(result.merchant, "Trader Joe's");
  assert.equal(result.purchaseDate, "2026-10-06");
  assert.deepEqual(result.rows.map((row) => row.kind), ["other", "item", "total"]);
  assert.equal(result.rows[1]?.text, "BANANAS");
  assert.equal(result.rows[1]?.price, "2.49");
  assert.equal(result.rows[1]?.name, "Bananas");
  assert.equal(result.rows[0]?.name, "");
  assert.equal(result.rows[1]?.taxed, false);
  assert.equal(bodies[0].model, "gpt-6.1-sol");
  assert.ok(bodies[0].messages[1].content[1].image_url.url.startsWith("data:image/jpeg;base64,"));

  await parser.parseReceipt("image/jpeg", jpegBytes, "No total was found.");
  assert.match(bodies[1].messages[1].content[0].text, /No total was found\./);
});

test("POST /v1/receipts/parse routes an authenticated image and note to receipt vision", async () => {
  const jpegBytes = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 0x01, 0x02]);
  let receivedNote: string | undefined;
  const mockParser = {
    async parseReceipt(contentType: string, bytes: Uint8Array, note?: string) {
      assert.equal(contentType, "image/jpeg");
      assert.deepEqual(bytes, jpegBytes);
      receivedNote = note;
      return { merchant: "Supermarket", category: "groceries", purchaseDate: "", expenseName: "",
        rows: [{ text: "Apples", price: "4.50", kind: "item" as const, taxed: true, name: "Apples" }] };
    },
  };
  const app = createApp(new MemoryRepository(), async (context) => context.req.header("x-user-id") ?? null, mockParser);

  const response = await app.request("/v1/receipts/parse", { method: "POST", headers: { "x-user-id": alex, "content-type": "image/jpeg" }, body: jpegBytes });
  assert.equal(response.status, 200);
  const data = await response.json() as any;
  assert.equal(data.rows[0].price, "4.50");
  assert.equal(receivedNote, undefined);

  const reread = await app.request(`/v1/receipts/parse?note=${encodeURIComponent("No total was found.")}`, {
    method: "POST", headers: { "x-user-id": alex, "content-type": "image/jpeg" }, body: jpegBytes });
  assert.equal(reread.status, 200);
  assert.equal(receivedNote, "No total was found.");

  const unauth = await app.request("/v1/receipts/parse", { method: "POST", headers: { "content-type": "image/jpeg" }, body: jpegBytes });
  assert.equal(unauth.status, 401);

  const heicBytes = Uint8Array.from([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]);
  const heicResponse = await app.request("/v1/receipts/parse", { method: "POST", headers: { "x-user-id": alex, "content-type": "image/heic" }, body: heicBytes });
  assert.equal(heicResponse.status, 415);
});
