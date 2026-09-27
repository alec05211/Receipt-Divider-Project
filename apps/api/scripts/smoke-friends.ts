import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import postgres from "postgres";
import { createApp } from "../src/app.ts";
import { PostgresRepository } from "../src/postgres-repository.ts";

const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) throw new Error("DATABASE_URL is required");
const repository = new PostgresRepository(databaseUrl), cleanup = postgres(databaseUrl, { max: 1, prepare: false, ssl: "require" });
const app = createApp(repository, async (context) => context.req.header("x-user-id") ?? null);
const left = randomUUID(), right = randomUUID(), suffix = randomUUID().slice(0, 8);
const json = (path: string, user: string, method = "GET", body?: unknown) => app.request(path, body === undefined
  ? { method, headers: { "x-user-id": user } }
  : { method, headers: { "x-user-id": user, "content-type": "application/json" }, body: JSON.stringify(body) });
try {
  for (const id of [left, right]) assert.equal((await json("/v1/profile", id, "PUT")).status, 200);
  assert.equal((await json("/v1/profile/identity", left, "PUT", { firstName: "Friend", lastName: "Left", username: `left_${suffix}` })).status, 200);
  assert.equal((await json("/v1/profile/identity", right, "PUT", { firstName: "Friend", lastName: "Right", username: `right_${suffix}` })).status, 200);
  const profile = await (await json("/v1/profile", left)).json() as { displayName: string };
  assert.equal(profile.displayName, "Friend Left");
  const requestResponse = await json("/v1/friend-requests", left, "POST", { username: `right_${suffix}` }); assert.equal(requestResponse.status, 201);
  const request = await requestResponse.json() as { requestId: string };
  assert.equal((await json(`/v1/friend-requests/${request.requestId}/accept`, right, "POST", {})).status, 200);
  const friends = await (await json("/v1/friends", left)).json() as Array<{ status: string }>;
  assert.equal(friends[0]?.status, "accepted");
  const people = await (await json("/v1/people", left)).json() as Array<{ linkedUserId?: string }>;
  assert.ok(people.some((person) => person.linkedUserId === right));
  console.log("Friends smoke test passed: identity, username invite, acceptance, and linked people.");
} finally {
  await cleanup`DELETE FROM user_profiles WHERE id IN (${left}, ${right})`;
  await Promise.all([repository.close(), cleanup.end()]);
}
