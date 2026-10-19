import { createHash } from "node:crypto";
import type { CreateExpenseInput, CreatePaymentInput, Expense, ExpenseAdjustment, ExpenseAmounts, ExpenseAmountsSummary, ExpenseCategory, ExpenseChanges, ExpenseItem, Payment, UUID } from "./types.ts";
import { adjustmentKinds, ApiError, expenseCategories, expenseItemKinds } from "./types.ts";

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

/** Names are 1–60 characters after trimming, the database's limit. */
export const personNameLimit = 60;
export function validPersonName(value: string, field: string): string {
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > personNameLimit) throw new ApiError(400, `${field} must contain 1–${personNameLimit} characters`, "invalid_name");
  return trimmed;
}

/** Why a username can't be someone's own: badly formed, or ending in "_dev", which only dev accounts may. */
export function usernameProblem(value: string): "invalid" | "reserved" | null {
  const username = value.trim().toLowerCase();
  if (!/^[a-z0-9_]{3,24}$/.test(username)) return "invalid";
  return username.endsWith("_dev") ? "reserved" : null;
}

/** A username to look someone up by; dev accounts' usernames are well formed too. */
export function validUsername(value: string): string {
  if (usernameProblem(value) === "invalid") throw new ApiError(400, "username must be 3–24 lowercase letters, numbers, or underscores", "invalid_username");
  return value.trim().toLowerCase();
}

/** A username someone may give themselves. */
export function validOwnUsername(value: string): string {
  const username = validUsername(value);
  if (usernameProblem(username) === "reserved") throw new ApiError(400, "username can’t end in _dev", "reserved_username");
  return username;
}

export function requireCurrency(value: unknown): string {
  if (typeof value !== "string" || !currencyPattern.test(value)) {
    throw new ApiError(400, "currency must be a three-letter uppercase code", "invalid_input");
  }
  return value;
}

/** Returns the trimmed name of an expense, which must contain 1–200 characters. */
export function requireDescription(value: unknown): string {
  if (typeof value !== "string" || !value.trim() || value.length > 200) {
    throw new ApiError(400, "description must contain 1–200 characters", "invalid_input");
  }
  return value.trim();
}

/**
 * Validates the fields of an expense edit, which must change at least one of them; returns them normalized. New amounts
 * are checked against the expense once it's loaded, by `editedExpenseInput`.
 */
export function validateExpenseChanges(changes: ExpenseChanges): ExpenseChanges {
  if (changes.description === undefined && changes.category === undefined && changes.transactionDate === undefined && changes.payerId === undefined && changes.amounts === undefined) {
    throw new ApiError(400, "provide description, category, transactionDate, payerId, or amounts", "invalid_input");
  }
  const result: ExpenseChanges = {};
  if (changes.description !== undefined) result.description = requireDescription(changes.description);
  if (changes.category !== undefined) result.category = optionalCategory(changes.category);
  if (changes.transactionDate !== undefined) { requireDate(changes.transactionDate); result.transactionDate = changes.transactionDate; }
  if (changes.payerId !== undefined) result.payerId = requireUuid(changes.payerId, "payerId");
  if (changes.amounts !== undefined) result.amounts = changes.amounts;
  if (changes.expectedUpdatedAt !== undefined) {
    if (typeof changes.expectedUpdatedAt !== "string" || Number.isNaN(Date.parse(changes.expectedUpdatedAt))) throw new ApiError(400, "expectedUpdatedAt must be an ISO 8601 date-time", "invalid_input");
    result.expectedUpdatedAt = changes.expectedUpdatedAt;
  }
  return result;
}

/** Refuses an edit made against an older version of the expense than the one saved now. */
export function requireCurrentVersion(expectedUpdatedAt: string | undefined, updatedAt: string): void {
  if (expectedUpdatedAt !== undefined && Date.parse(expectedUpdatedAt) !== Date.parse(updatedAt)) {
    throw new ApiError(409, "this expense was changed since you opened it", "stale_expense");
  }
}

/** The `updatedAt` an edit saves: now, or a millisecond after `previous` if the clock hasn't passed it, so every edit is distinct. */
export function nextUpdatedAt(previous: string): string {
  return new Date(Math.max(Date.now(), Date.parse(previous) + 1)).toISOString();
}

/**
 * The expense as it would be saved with new amounts and payer, checked by the same rules as a new expense, with its IDs
 * lowercased. Currency and evidence stay as they are; category is edited separately.
 */
export function editedExpenseInput(expense: Expense, description: string, transactionDate: string, amounts: ExpenseAmounts, payerId: UUID): CreateExpenseInput {
  const input: CreateExpenseInput = {
    clientRequestId: expense.clientRequestId, description, transactionDate, payerId, currency: expense.currency,
    totalCents: amounts.totalCents, items: amounts.items, adjustments: amounts.adjustments, allocations: amounts.allocations,
  };
  validateExpenseAmounts(input);
  return input;
}

type Amounts = Pick<Expense, "totalCents" | "items" | "adjustments" | "allocations">;

/** An expense's saved amounts, copied so validating them as an edit can't change the expense. */
export function currentAmounts(expense: Expense): ExpenseAmounts {
  return structuredClone({ totalCents: expense.totalCents, items: expense.items, adjustments: expense.adjustments, allocations: expense.allocations.map(({ userId, amountCents }) => ({ userId, amountCents })) });
}

/** Whether two versions of an expense have the same amounts, whatever order allocations and item owners are listed in. */
export function sameAmounts(left: Amounts, right: Amounts): boolean {
  const normalized = (expense: Amounts) => ({
    totalCents: expense.totalCents,
    items: expense.items.map((item) => ({ ...item, ownerIds: [...item.ownerIds].sort() })),
    adjustments: expense.adjustments.map(({ kind, amountCents, rate }) => ({ kind, amountCents, rate })),
    allocations: [...expense.allocations].sort((a, b) => a.userId.localeCompare(b.userId)).map(({ userId, amountCents }) => ({ userId, amountCents })),
  });
  return fingerprint(normalized(left)) === fingerprint(normalized(right));
}

/** One side of an amount edit's revision: enough for a client to show what changed. */
export function amountsSummary(expense: Pick<Expense, "totalCents" | "adjustments" | "allocations">): ExpenseAmountsSummary {
  return {
    totalCents: expense.totalCents,
    adjustments: expense.adjustments.map(({ kind, amountCents }) => ({ kind, amountCents })),
    allocations: expense.allocations.map(({ userId, amountCents }) => ({ userId, amountCents })),
  };
}

/** Returns the category, or null when none is given. */
export function optionalCategory(value: unknown): ExpenseCategory | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || !(expenseCategories as readonly string[]).includes(value)) {
    throw new ApiError(400, `category must be one of ${expenseCategories.join(", ")}`, "invalid_input");
  }
  return value as ExpenseCategory;
}

/**
 * Validates `input` and lowercases its IDs in place. A missing or null category is removed, so requests without
 * one keep the retry fingerprint they had before categories existed.
 */
export function validateExpense(input: CreateExpenseInput): void {
  input.clientRequestId = requireUuid(input.clientRequestId, "clientRequestId");
  input.payerId = requireUuid(input.payerId, "payerId");
  requireCurrency(input.currency);
  requireDescription(input.description);
  const category = optionalCategory(input.category);
  if (category) input.category = category; else delete input.category;
  requireDate(input.transactionDate);
  validateExpenseAmounts(input);
  const evidenceIds = input.evidenceIds ?? [];
  if (!Array.isArray(evidenceIds) || evidenceIds.length > 10) throw new ApiError(400, "an expense may have at most 10 evidence images", "invalid_input");
  const uniqueEvidence = new Set<string>();
  if (input.evidenceIds) input.evidenceIds = evidenceIds.map((id) => requireUuid(id, "evidenceId"));
  for (const evidenceId of input.evidenceIds ?? []) {
    if (uniqueEvidence.has(evidenceId)) throw new ApiError(400, "evidenceIds must be unique", "invalid_input");
    uniqueEvidence.add(evidenceId);
  }
}

/**
 * Validates an expense's total, items, adjustments and allocations against its payer, lowercasing IDs in place. New
 * expenses and amount edits share it so both follow the same rules.
 */
export function validateExpenseAmounts(input: CreateExpenseInput): void {
  requireCents(input.totalCents, "totalCents", false);
  const items = input.items ?? [];
  if (!Array.isArray(items) || items.length > 250) {
    throw new ApiError(400, "an expense may have at most 250 items", "invalid_input");
  }
  if (!Array.isArray(input.allocations) || input.allocations.length === 0 || input.allocations.length > 100) {
    throw new ApiError(400, "an expense must have 1–100 allocations", "invalid_input");
  }

  // Items need not add up to the total: a receipt split evenly uses its printed total even when recognition missed a line.
  for (const item of items) {
    if (!item.name?.trim() || item.name.length > 300) throw new ApiError(400, "each item needs a name", "invalid_input");
    requireCents(item.amountCents, "item amountCents", false);
    requireCents(item.localOffsetCents ?? 0, "item localOffsetCents", true);
    requireCents(item.globalOffsetCents ?? item.offsetCents ?? 0, "item globalOffsetCents", true);
    if (item.kind !== undefined && !(expenseItemKinds as readonly string[]).includes(item.kind)) throw new ApiError(400, `item kind must be one of ${expenseItemKinds.join(", ")}`, "invalid_input");
    if (item.taxed !== undefined && typeof item.taxed !== "boolean") throw new ApiError(400, "item taxed must be true or false", "invalid_input");
  }
  const adjustments = input.adjustments ?? [];
  if (!Array.isArray(adjustments) || adjustments.length > 20) throw new ApiError(400, "an expense may have at most 20 adjustments", "invalid_input");
  for (const adjustment of adjustments) {
    if (!(adjustmentKinds as readonly string[]).includes(adjustment?.kind)) throw new ApiError(400, `adjustment kind must be one of ${adjustmentKinds.join(", ")}`, "invalid_input");
    requireCents(adjustment.amountCents, "adjustment amountCents", false, true);
    if (adjustment.rate != null && (typeof adjustment.rate !== "number" || !Number.isFinite(adjustment.rate) || adjustment.rate < 0 || adjustment.rate >= 1000)) {
      throw new ApiError(400, "adjustment rate must be null or a fraction from 0 up to 1000", "invalid_input");
    }
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
  for (const item of items) {
    if (item.ownerIds === undefined) continue;
    if (!Array.isArray(item.ownerIds) || item.ownerIds.length > 100) throw new ApiError(400, "item ownerIds must be a list of at most 100 people", "invalid_input");
    item.ownerIds = item.ownerIds.map((id) => requireUuid(id, "item ownerId"));
    if (new Set(item.ownerIds).size !== item.ownerIds.length) throw new ApiError(400, "item ownerIds must be unique", "invalid_input");
  }
  for (const item of expenseItems(input)) {
    if (item.ownerIds.some((id) => id !== input.payerId && !memberIds.has(id))) throw new ApiError(422, "every item owner must be the payer or have an allocation", "invalid_owner");
  }
}

/**
 * The items an expense is saved with: an expense without items becomes one item for its total owned by everyone
 * allocated, and an item without owners belongs to the payer. Leaves `input` unchanged so its fingerprint doesn't.
 */
export function expenseItems(input: CreateExpenseInput): ExpenseItem[] {
  if (!input.items?.length) {
    return [{ name: input.description.trim(), amountCents: input.totalCents, localOffsetCents: 0, globalOffsetCents: 0, kind: "item", taxed: true, ownerIds: input.allocations.map((allocation) => allocation.userId) }];
  }
  return input.items.map((item) => ({
    name: item.name.trim(), amountCents: item.amountCents, localOffsetCents: item.localOffsetCents ?? 0,
    globalOffsetCents: item.globalOffsetCents ?? item.offsetCents ?? 0, kind: item.kind ?? "item", taxed: item.taxed ?? true,
    ownerIds: item.ownerIds?.length ? [...item.ownerIds] : [input.payerId],
  }));
}

/** The adjustments an expense is saved with, in receipt order. Leaves `input` unchanged so its fingerprint doesn't. */
export function expenseAdjustments(input: CreateExpenseInput): ExpenseAdjustment[] {
  return (input.adjustments ?? []).map((adjustment) => ({ kind: adjustment.kind, amountCents: adjustment.amountCents, rate: adjustment.rate ?? null }));
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
export function filterTransactions<E extends Expense>(userIds: UUID[], expenses: E[], payments: Payment[]): { expenses: E[]; payments: Payment[] } {
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
