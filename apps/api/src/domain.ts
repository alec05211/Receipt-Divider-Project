import { createHash } from "node:crypto";
import type { CreateExpenseInput, CreatePaymentInput, Expense, Payment, UUID } from "./types.ts";
import { ApiError } from "./types.ts";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const datePattern = /^\d{4}-\d{2}-\d{2}$/;
const currencyPattern = /^[A-Z]{3}$/;

/** Returns the UUID in lowercase, the form PostgreSQL and the auth token use, so IDs compare equal whatever case a client sends. */
export function requireUuid(value: unknown, field: string): UUID {
  if (typeof value !== "string" || !uuidPattern.test(value)) {
    throw new ApiError(400, `${field} must be a UUID`, "invalid_input");
  }
  return value.toLowerCase();
}

/** Trims a user search query; 2–60 characters keeps results relevant and discourages listing everyone. */
export function searchTerm(value: string): string {
  const term = value.trim().replace(/\s+/g, " ");
  if (term.length < 2 || term.length > 60) throw new ApiError(400, "search must contain 2–60 characters", "invalid_input");
  return term;
}

export function requireCurrency(value: unknown): string {
  if (typeof value !== "string" || !currencyPattern.test(value)) {
    throw new ApiError(400, "currency must be a three-letter uppercase code", "invalid_input");
  }
  return value;
}

/** Validates `input` and lowercases its IDs in place. */
export function validateExpense(input: CreateExpenseInput): void {
  input.clientRequestId = requireUuid(input.clientRequestId, "clientRequestId");
  input.payerId = requireUuid(input.payerId, "payerId");
  requireCurrency(input.currency);
  requireCents(input.totalCents, "totalCents", false);
  if (!input.description?.trim() || input.description.length > 200) {
    throw new ApiError(400, "description must contain 1–200 characters", "invalid_input");
  }
  requireDate(input.transactionDate);
  const items = input.items ?? [];
  if (!Array.isArray(items) || items.length > 250) {
    throw new ApiError(400, "an expense may have at most 250 items", "invalid_input");
  }
  if (!Array.isArray(input.allocations) || input.allocations.length === 0 || input.allocations.length > 100) {
    throw new ApiError(400, "an expense must have 1–100 allocations", "invalid_input");
  }

  let total = 0;
  for (const item of items) {
    if (!item.name?.trim() || item.name.length > 300) throw new ApiError(400, "each item needs a name", "invalid_input");
    requireCents(item.amountCents, "item amountCents", false);
    requireCents(item.offsetCents ?? 0, "item offsetCents", true);
    total += item.amountCents + (item.offsetCents ?? 0);
  }
  if (items.length && total !== input.totalCents) {
    throw new ApiError(422, `items total ${total} does not equal expense total ${input.totalCents}`, "item_total_mismatch");
  }

  const memberIds = new Set<string>();
  let allocationTotal = 0;
  for (const allocation of input.allocations) {
    allocation.userId = requireUuid(allocation.userId, "allocation userId");
    requireCents(allocation.amountCents, "allocation amountCents", false, true);
    if (memberIds.has(allocation.userId)) throw new ApiError(400, "each person may be allocated once", "invalid_input");
    memberIds.add(allocation.userId);
    allocationTotal += allocation.amountCents;
  }
  if (allocationTotal !== input.totalCents) {
    throw new ApiError(422, `allocations total ${allocationTotal} does not equal expense total ${input.totalCents}`, "allocation_mismatch");
  }
  const evidenceIds = input.evidenceIds ?? [];
  if (!Array.isArray(evidenceIds) || evidenceIds.length > 10) throw new ApiError(400, "an expense may have at most 10 evidence images", "invalid_input");
  const uniqueEvidence = new Set<string>();
  if (input.evidenceIds) input.evidenceIds = evidenceIds.map((id) => requireUuid(id, "evidenceId"));
  for (const evidenceId of input.evidenceIds ?? []) {
    if (uniqueEvidence.has(evidenceId)) throw new ApiError(400, "evidenceIds must be unique", "invalid_input");
    uniqueEvidence.add(evidenceId);
  }
}

/** Validates `input` and lowercases its IDs in place. */
export function validatePayment(recorderId: UUID, input: CreatePaymentInput): void {
  input.clientRequestId = requireUuid(input.clientRequestId, "clientRequestId");
  input.fromUserId = requireUuid(input.fromUserId, "fromUserId");
  input.toUserId = requireUuid(input.toUserId, "toUserId");
  if (input.fromUserId !== recorderId && input.toUserId !== recorderId) throw new ApiError(422, "you can only record payments you sent or received", "invalid_person");
  if (input.fromUserId === input.toUserId) throw new ApiError(400, "payment sender and recipient must differ", "invalid_input");
  requireCents(input.amountCents, "amountCents", false);
  requireDate(input.transactionDate);
}

/**
 * What each other person owes `userId` (negative: what `userId` owes them). Everyone on an expense owes their share
 * to its payer, and a repayment reduces what the sender owes the recipient.
 */
export function calculateBalances(userId: UUID, expenses: Expense[], payments: Payment[]): Record<UUID, number> {
  const balances: Record<UUID, number> = {};
  const add = (otherId: UUID, cents: number) => { balances[otherId] = (balances[otherId] ?? 0) + cents; };
  for (const expense of expenses) {
    for (const allocation of expense.allocations) {
      if (allocation.userId === expense.payerId) continue;
      if (expense.payerId === userId) add(allocation.userId, allocation.amountCents);
      else if (allocation.userId === userId) add(expense.payerId, -allocation.amountCents);
    }
  }
  for (const payment of payments) {
    if (payment.fromUserId === userId) add(payment.toUserId, payment.amountCents);
    else if (payment.toUserId === userId) add(payment.fromUserId, -payment.amountCents);
  }
  return balances;
}

/** Keeps the transactions involving any of `userIds`; used by saved filters, which never change balances. */
export function filterTransactions(userIds: UUID[], expenses: Expense[], payments: Payment[]): { expenses: Expense[]; payments: Payment[] } {
  const selected = new Set(userIds);
  return {
    expenses: expenses.filter((expense) => selected.has(expense.payerId) || expense.allocations.some((allocation) => selected.has(allocation.userId))),
    payments: payments.filter((payment) => selected.has(payment.fromUserId) || selected.has(payment.toUserId)),
  };
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
