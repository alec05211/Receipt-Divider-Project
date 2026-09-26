import { createHash } from "node:crypto";
import type { CreateExpenseInput, CreatePaymentInput, Expense, Payment, UUID } from "./types.js";
import { ApiError } from "./types.js";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const datePattern = /^\d{4}-\d{2}-\d{2}$/;
const currencyPattern = /^[A-Z]{3}$/;

export function requireUuid(value: unknown, field: string): UUID {
  if (typeof value !== "string" || !uuidPattern.test(value)) {
    throw new ApiError(400, `${field} must be a UUID`, "invalid_input");
  }
  return value;
}

export function requireCurrency(value: unknown): string {
  if (typeof value !== "string" || !currencyPattern.test(value)) {
    throw new ApiError(400, "currency must be a three-letter uppercase code", "invalid_input");
  }
  return value;
}

export function validateExpense(input: CreateExpenseInput): number {
  requireUuid(input.clientRequestId, "clientRequestId");
  requireUuid(input.payerId, "payerId");
  requireCurrency(input.currency);
  if (input.receiptId !== undefined) requireUuid(input.receiptId, "receiptId");
  if (!input.description?.trim() || input.description.length > 200) {
    throw new ApiError(400, "description must contain 1–200 characters", "invalid_input");
  }
  requireDate(input.transactionDate);
  if (!Array.isArray(input.items) || input.items.length === 0 || input.items.length > 250) {
    throw new ApiError(400, "an expense must have 1–250 items", "invalid_input");
  }
  if (!Array.isArray(input.allocations) || input.allocations.length === 0 || input.allocations.length > 100) {
    throw new ApiError(400, "an expense must have 1–100 allocations", "invalid_input");
  }

  let total = 0;
  for (const item of input.items) {
    if (!item.name?.trim() || item.name.length > 300) throw new ApiError(400, "each item needs a name", "invalid_input");
    requireCents(item.amountCents, "item amountCents", false);
    requireCents(item.offsetCents ?? 0, "item offsetCents", true);
    total += item.amountCents + (item.offsetCents ?? 0);
  }
  requireCents(total, "expense total", false);

  const memberIds = new Set<string>();
  let allocationTotal = 0;
  for (const allocation of input.allocations) {
    requireUuid(allocation.userId, "allocation userId");
    requireCents(allocation.amountCents, "allocation amountCents", false, true);
    if (memberIds.has(allocation.userId)) throw new ApiError(400, "each member may be allocated once", "invalid_input");
    memberIds.add(allocation.userId);
    allocationTotal += allocation.amountCents;
  }
  if (allocationTotal !== total) {
    throw new ApiError(422, `allocations total ${allocationTotal} does not equal expense total ${total}`, "allocation_mismatch");
  }
  return total;
}

export function validatePayment(input: CreatePaymentInput): void {
  requireUuid(input.clientRequestId, "clientRequestId");
  requireUuid(input.fromUserId, "fromUserId");
  requireUuid(input.toUserId, "toUserId");
  if (input.fromUserId === input.toUserId) throw new ApiError(400, "payment sender and recipient must differ", "invalid_input");
  requireCents(input.amountCents, "amountCents", false);
  requireDate(input.transactionDate);
}

export function calculateBalances(memberIds: UUID[], expenses: Expense[], payments: Payment[]): Record<UUID, number> {
  const balances = Object.fromEntries(memberIds.map((id) => [id, 0]));
  for (const expense of expenses) {
    balances[expense.payerId] = (balances[expense.payerId] ?? 0) + expense.totalCents;
    for (const allocation of expense.allocations) {
      balances[allocation.userId] = (balances[allocation.userId] ?? 0) - allocation.amountCents;
    }
  }
  for (const payment of payments) {
    balances[payment.fromUserId] = (balances[payment.fromUserId] ?? 0) + payment.amountCents;
    balances[payment.toUserId] = (balances[payment.toUserId] ?? 0) - payment.amountCents;
  }
  return balances;
}

export function fingerprint(value: unknown): string {
  return createHash("sha256").update(JSON.stringify(canonicalize(value))).digest("hex");
}

export function imageEtag(bytes: Uint8Array): string {
  return `"${createHash("sha256").update(bytes).digest("hex")}"`;
}

export function hasImageSignature(contentType: string, bytes: Uint8Array): boolean {
  if (contentType === "image/jpeg") return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (contentType === "image/png") return startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (contentType === "image/webp") {
    return ascii(bytes, 0, 4) === "RIFF" && ascii(bytes, 8, 4) === "WEBP";
  }
  if (contentType === "image/heic" || contentType === "image/heif") {
    return ascii(bytes, 4, 4) === "ftyp" && ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].includes(ascii(bytes, 8, 4));
  }
  return false;
}

function requireDate(value: unknown): void {
  if (typeof value !== "string" || !datePattern.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) {
    throw new ApiError(400, "transactionDate must be a valid YYYY-MM-DD calendar date", "invalid_input");
  }
}

function requireCents(value: unknown, field: string, allowNegative: boolean, allowZero = false): void {
  if (!Number.isSafeInteger(value) || (!allowNegative && (allowZero ? Number(value) < 0 : Number(value) <= 0))) {
    throw new ApiError(400, `${field} must be ${allowNegative ? "an" : "a positive"} integer number of cents`, "invalid_input");
  }
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).sort(([left], [right]) => left.localeCompare(right)).map(([key, item]) => [key, canonicalize(item)]));
  }
  return value;
}

function startsWith(bytes: Uint8Array, prefix: number[]): boolean {
  return bytes.length >= prefix.length && prefix.every((value, index) => bytes[index] === value);
}

function ascii(bytes: Uint8Array, start: number, length: number): string {
  if (bytes.length < start + length) return "";
  return String.fromCharCode(...bytes.slice(start, start + length));
}
