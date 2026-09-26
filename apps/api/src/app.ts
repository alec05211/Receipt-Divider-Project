import { Hono } from "hono";
import type { Context } from "hono";
import { hasImageSignature, requireCurrency, requireUuid } from "./domain.js";
import type { CreateExpenseInput, CreatePaymentInput, LedgerRepository, UUID } from "./types.js";
import { ApiError } from "./types.js";

const avatarLimit = 5 * 1024 * 1024;
const receiptLimit = 15 * 1024 * 1024;
const allowedTypes = new Set(["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"]);

export type Authenticator = (context: Context) => Promise<UUID | null>;

export function createApp(repository: LedgerRepository, authenticate: Authenticator) {
  const app = new Hono();

  app.onError((error, context) => {
    if (error instanceof ApiError) return context.json({ error: { code: error.code, message: error.message } }, error.status as 400);
    console.error(error);
    return context.json({ error: { code: "internal_error", message: "The request could not be completed" } }, 500);
  });

  app.get("/health", (context) => context.json({ ok: true }));

  app.use("/v1/*", async (context, next) => {
    const userId = await authenticate(context);
    if (!userId) throw new ApiError(401, "authentication is required", "unauthorized");
    context.set("userId", requireUuid(userId, "authenticated user id"));
    await next();
  });

  app.put("/v1/profile", async (context) => {
    const body = await jsonBody(context);
    const profile = await repository.upsertProfile(userId(context), stringField(body, "displayName"));
    return context.json(profile);
  });

  app.put("/v1/profile/avatar", async (context) => {
    const image = await imageBody(context, avatarLimit);
    const etag = await repository.putAvatar(userId(context), image.contentType, image.bytes);
    return context.json({ etag });
  });

  app.get("/v1/users/:userId/avatar", async (context) => {
    const image = await repository.getAvatar(userId(context), requireUuid(context.req.param("userId"), "userId"));
    return imageResponse(context, image);
  });

  app.post("/v1/groups", async (context) => {
    const body = await jsonBody(context);
    const group = await repository.createGroup(
      userId(context), stringField(body, "name"), requireCurrency(body.currency),
    );
    return context.json(group, 201);
  });

  app.post("/v1/groups/:groupId/members", async (context) => {
    const body = await jsonBody(context);
    await repository.addMember(userId(context), groupId(context), requireUuid(body.userId, "userId"));
    return context.body(null, 204);
  });

  app.get("/v1/groups/:groupId/snapshot", async (context) => {
    return context.json(await repository.getSnapshot(userId(context), groupId(context)));
  });

  app.post("/v1/groups/:groupId/receipts", async (context) => {
    const image = await imageBody(context, receiptLimit);
    const receiptId = await repository.createReceipt(userId(context), groupId(context), image.contentType, image.bytes);
    return context.json({ id: receiptId }, 201);
  });

  app.get("/v1/receipts/:receiptId/image", async (context) => {
    const image = await repository.getReceipt(userId(context), requireUuid(context.req.param("receiptId"), "receiptId"));
    return imageResponse(context, image);
  });

  app.post("/v1/groups/:groupId/expenses", async (context) => {
    const input = await jsonBody(context) as unknown as CreateExpenseInput;
    return context.json(await repository.createExpense(userId(context), groupId(context), input), 201);
  });

  app.post("/v1/groups/:groupId/payments", async (context) => {
    const input = await jsonBody(context) as unknown as CreatePaymentInput;
    return context.json(await repository.createPayment(userId(context), groupId(context), input), 201);
  });

  return app;
}

function userId(context: Context): UUID {
  return context.get("userId") as UUID;
}

function groupId(context: Context): UUID {
  return requireUuid(context.req.param("groupId"), "groupId");
}

async function jsonBody(context: Context): Promise<Record<string, unknown>> {
  const contentType = context.req.header("content-type") ?? "";
  if (!contentType.includes("application/json")) throw new ApiError(415, "Content-Type must be application/json", "unsupported_media_type");
  try {
    const value = await context.req.json();
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error();
    return value as Record<string, unknown>;
  } catch {
    throw new ApiError(400, "request body must be a JSON object", "invalid_json");
  }
}

function stringField(body: Record<string, unknown>, key: string): string {
  const value = body[key];
  if (typeof value !== "string") throw new ApiError(400, `${key} must be a string`, "invalid_input");
  return value;
}

async function imageBody(context: Context, limit: number): Promise<{ contentType: string; bytes: Uint8Array }> {
  const contentType = (context.req.header("content-type") ?? "").split(";")[0]!.toLowerCase();
  if (!allowedTypes.has(contentType)) throw new ApiError(415, "image must be JPEG, PNG, HEIC, HEIF, or WebP", "unsupported_media_type");
  const declared = Number(context.req.header("content-length") ?? 0);
  if (declared > limit) throw new ApiError(413, `image exceeds the ${Math.floor(limit / 1024 / 1024)} MB limit`, "image_too_large");
  const bytes = new Uint8Array(await context.req.arrayBuffer());
  if (bytes.length === 0) throw new ApiError(400, "image body is empty", "invalid_input");
  if (bytes.length > limit) throw new ApiError(413, `image exceeds the ${Math.floor(limit / 1024 / 1024)} MB limit`, "image_too_large");
  if (!hasImageSignature(contentType, bytes)) throw new ApiError(415, "image bytes do not match Content-Type", "invalid_image");
  return { contentType, bytes };
}

function imageResponse(context: Context, image: { contentType: string; bytes: Uint8Array; etag: string } | null): Response {
  if (!image) throw new ApiError(404, "image not found", "not_found");
  if (context.req.header("if-none-match") === image.etag) return context.body(null, 304);
  return new Response(image.bytes as BodyInit, {
    headers: { "Content-Type": image.contentType, "Content-Length": String(image.bytes.length), ETag: image.etag, "Cache-Control": "private, max-age=86400" },
  });
}

declare module "hono" {
  interface ContextVariableMap {
    userId: UUID;
  }
}
