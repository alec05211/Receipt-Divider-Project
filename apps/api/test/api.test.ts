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

async function setup() {
  const app = createApp(new MemoryRepository(), async (context) => context.req.header("x-user-id") ?? null);
  for (const user of [alex, jamie, stranger, morgan]) assert.equal((await request(app, "/v1/profile", user, { method: "PUT" })).status, 200);
  return { app };
}

/** Alex is friends with Jamie and Morgan; the stranger is nobody's friend. */
async function setupFriends() {
  const { app } = await setup();
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

test("idempotency and exact totals protect canonical expenses", async () => {
  const { app } = await setupFriends();
  const input = expense("40000000-0000-4000-8000-000000000001", alex, [[alex, 2000], [jamie, 2000]], { items: [{ name: "Dinner", amountCents: 4000 }] });
  const first = await jsonRequest(app, "/v1/expenses", alex, "POST", input), retry = await jsonRequest(app, "/v1/expenses", alex, "POST", input);
  assert.equal((await first.json() as { id: string }).id, (await retry.json() as { id: string }).id);
  assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", { ...input, description: "Changed" })).status, 409);
  assert.equal((await jsonRequest(app, "/v1/expenses", alex, "POST", { ...input, clientRequestId: "40000000-0000-4000-8000-000000000002", totalCents: 3999 })).status, 422);
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

test("Supabase JWT authentication accepts only signed authenticated-user tokens", async () => {
  const projectUrl = "https://receipt-divider.supabase.co", issuer = `${projectUrl}/auth/v1`, { publicKey, privateKey } = await generateKeyPair("ES256");
  const publicJwk = await exportJWK(publicKey); publicJwk.kid = "test-key"; publicJwk.alg = "ES256";
  const app = createApp(new MemoryRepository(), createSupabaseAuthenticator(projectUrl, createLocalJWKSet({ keys: [publicJwk] })));
  async function token(role: string, subject = alex) { return new SignJWT({ role }).setProtectedHeader({ alg: "ES256", kid: "test-key" }).setIssuer(issuer).setAudience("authenticated").setSubject(subject).setIssuedAt().setExpirationTime("5m").sign(privateKey); }
  const valid = await app.request("/v1/profile", { method: "PUT", headers: { authorization: `Bearer ${await token("authenticated")}`} }); assert.equal(valid.status, 200);
  const wrongRole = await app.request("/v1/profile", { method: "PUT", headers: { authorization: `Bearer ${await token("anon")}`} }); assert.equal(wrongRole.status, 401);
});
