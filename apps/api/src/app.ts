import { Hono } from "hono";
import type { Context } from "hono";
import { hasImageSignature, requireUuid } from "./domain.ts";
import type { CreateExpenseInput, CreatePaymentInput, EvidenceKind, ExpenseChanges, LedgerRepository, UUID } from "./types.ts";
import { ApiError } from "./types.ts";

const avatarLimit = 5 * 1024 * 1024;
const evidenceLimit = 15 * 1024 * 1024;
/** Recognized receipt text; generous for a long itemized receipt. */
const evidenceTextLimit = 100_000;
const allowedTypes = new Set(["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"]);
const evidenceKinds = new Set<EvidenceKind>(["receipt", "restaurant_check", "ticket_confirmation", "other"]);

export type Authenticator = (context: Context) => Promise<UUID | null>;

export function createApp(repository: LedgerRepository, authenticate: Authenticator) {
  const app = new Hono();

  app.onError((error, context) => {
    if (error instanceof ApiError) return context.json({ error: { code: error.code, message: error.message } }, error.status as 400);
    console.error(error);
    return context.json({ error: { code: "internal_error", message: "The request could not be completed" } }, 500);
  });

  app.get("/health", (context) => context.json({ ok: true }));
  app.get("/ready", async (context) => {
    await repository.checkHealth();
    return context.json({ ok: true });
  });
  app.use("/v1/*", async (context, next) => {
    const authenticatedId = await authenticate(context);
    if (!authenticatedId) throw new ApiError(401, "authentication is required", "unauthorized");
    context.set("userId", requireUuid(authenticatedId, "authenticated user id"));
    await next();
  });

  app.put("/v1/profile", async (context) => context.json(await repository.ensureProfile(userId(context))));
  app.get("/v1/profile", async (context) => context.json(await repository.getProfile(userId(context))));
  app.put("/v1/profile/identity", async (context) => {
    const body = await jsonBody(context);
    return context.json(await repository.updateIdentity(userId(context), stringField(body, "firstName"), stringField(body, "lastName"), stringField(body, "username")));
  });
  app.put("/v1/profile/avatar", async (context) => {
    const image = await imageBody(context, avatarLimit);
    return context.json({ etag: await repository.putAvatar(userId(context), image.contentType, image.bytes) });
  });
  app.get("/v1/users/:userId/avatar", async (context) => imageResponse(context,
    await repository.getAvatar(userId(context), requireUuid(context.req.param("userId"), "userId"))));

  app.get("/v1/users/search", async (context) => context.json(await repository.searchUsers(userId(context), context.req.query("q") ?? "")));
  app.get("/v1/friends", async (context) => context.json(await repository.listFriends(userId(context))));
  app.post("/v1/friend-requests", async (context) => {
    const body = await jsonBody(context);
    return context.json(await repository.requestFriend(userId(context), stringField(body, "username")), 201);
  });
  app.post("/v1/friend-requests/:requestId/accept", async (context) => context.json(
    await repository.acceptFriend(userId(context), requireUuid(context.req.param("requestId"), "requestId"))));
  app.delete("/v1/friends/:userId", async (context) => {
    await repository.removeFriend(userId(context), requireUuid(context.req.param("userId"), "userId"));
    return context.body(null, 204);
  });

  app.post("/v1/saved-filters", async (context) => {
    const body = await jsonBody(context);
    if (!Array.isArray(body.userIds)) throw new ApiError(400, "userIds must be an array", "invalid_input");
    const userIds = body.userIds.map((id) => requireUuid(id, "userId"));
    return context.json(await repository.createSavedFilter(userId(context), stringField(body, "name"), userIds), 201);
  });
  app.get("/v1/saved-filters", async (context) => context.json(await repository.listSavedFilters(userId(context))));

  app.post("/v1/evidence", async (context) => {
    const kind = evidenceKind(context.req.query("kind"));
    const image = await imageBody(context, evidenceLimit);
    return context.json(await repository.createEvidence(userId(context), kind, image.contentType, image.bytes), 201);
  });
  app.get("/v1/evidence/:evidenceId/image", async (context) => imageResponse(context,
    await repository.getEvidence(userId(context), requireUuid(context.req.param("evidenceId"), "evidenceId"))));
  app.put("/v1/evidence/:evidenceId/text", async (context) => {
    const text = stringField(await jsonBody(context), "text");
    if (text.length > evidenceTextLimit) throw new ApiError(400, `text must be at most ${evidenceTextLimit} characters`, "invalid_input");
    if (!await repository.putEvidenceText(userId(context), requireUuid(context.req.param("evidenceId"), "evidenceId"), text)) throw new ApiError(404, "evidence not found", "not_found");
    return context.body(null, 204);
  });

  app.post("/v1/expenses", async (context) => context.json(
    await repository.createExpense(userId(context), await jsonBody(context) as unknown as CreateExpenseInput), 201));
  app.patch("/v1/expenses/:expenseId", async (context) => {
    const body = await jsonBody(context);
    const changes: ExpenseChanges = {};
    if (body.description !== undefined) changes.description = stringField(body, "description");
    if (body.transactionDate !== undefined) changes.transactionDate = stringField(body, "transactionDate");
    return context.json(await repository.updateExpense(userId(context), requireUuid(context.req.param("expenseId"), "expenseId"), changes));
  });
  app.post("/v1/payments", async (context) => context.json(
    await repository.createPayment(userId(context), await jsonBody(context) as unknown as CreatePaymentInput), 201));
  app.post("/v1/developer/reset-ledger", async (context) => {
    if ((await jsonBody(context)).confirm !== "DELETE") throw new ApiError(400, "confirm must be \"DELETE\"", "invalid_input");
    await repository.resetLedgerData(userId(context));
    return context.body(null, 204);
  });
  app.get("/v1/transactions", async (context) => {
    const rawFilterId = context.req.query("filterId");
    return context.json(await repository.getSnapshot(userId(context), rawFilterId ? requireUuid(rawFilterId, "filterId") : undefined));
  });

  return app;
}

function userId(context: Context): UUID { return context.get("userId") as UUID; }

async function jsonBody(context: Context): Promise<Record<string, unknown>> {
  if (!(context.req.header("content-type") ?? "").includes("application/json")) throw new ApiError(415, "Content-Type must be application/json", "unsupported_media_type");
  try {
    const value = await context.req.json();
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value as Record<string, unknown>;
  } catch { throw new ApiError(400, "request body must be a JSON object", "invalid_json"); }
}

function stringField(body: Record<string, unknown>, key: string): string {
  const value = body[key];
  if (typeof value !== "string") throw new ApiError(400, `${key} must be a string`, "invalid_input");
  return value;
}

function evidenceKind(value: string | undefined): EvidenceKind {
  const kind = value ?? "other";
  if (!evidenceKinds.has(kind as EvidenceKind)) throw new ApiError(400, "kind must be receipt, restaurant_check, ticket_confirmation, or other", "invalid_input");
  return kind as EvidenceKind;
}

async function imageBody(context: Context, limit: number): Promise<{ contentType: string; bytes: Uint8Array }> {
  const contentType = (context.req.header("content-type") ?? "").split(";")[0]!.toLowerCase();
  if (!allowedTypes.has(contentType)) throw new ApiError(415, "image must be JPEG, PNG, HEIC, HEIF, or WebP", "unsupported_media_type");
  const declared = Number(context.req.header("content-length") ?? 0);
  if (declared > limit) throw new ApiError(413, `image exceeds the ${Math.floor(limit / 1024 / 1024)} MB limit`, "image_too_large");
  const bytes = new Uint8Array(await context.req.arrayBuffer());
  if (!bytes.length) throw new ApiError(400, "image body is empty", "invalid_input");
  if (bytes.length > limit) throw new ApiError(413, `image exceeds the ${Math.floor(limit / 1024 / 1024)} MB limit`, "image_too_large");
  if (!hasImageSignature(contentType, bytes)) throw new ApiError(415, "image bytes do not match Content-Type", "invalid_image");
  return { contentType, bytes };
}

function imageResponse(context: Context, image: { contentType: string; bytes: Uint8Array; etag: string } | null): Response {
  if (!image) throw new ApiError(404, "image not found", "not_found");
  if (context.req.header("if-none-match") === image.etag) return context.body(null, 304);
  return new Response(image.bytes as BodyInit, { headers: { "Content-Type": image.contentType, "Content-Length": String(image.bytes.length), ETag: image.etag, "Cache-Control": "private, max-age=86400" } });
}

declare module "hono" { interface ContextVariableMap { userId: UUID; } }
