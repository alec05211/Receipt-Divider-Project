import { randomUUID } from "node:crypto";
import { calculateBalances, fingerprint, imageEtag, validateExpense, validatePayment } from "./domain.js";
import type {
  CreateExpenseInput,
  CreatePaymentInput,
  Expense,
  Group,
  GroupSnapshot,
  LedgerRepository,
  Payment,
  Profile,
  StoredImage,
  UUID,
} from "./types.js";
import { ApiError } from "./types.js";

interface ImageRecord extends StoredImage {
  groupId?: UUID;
}

/** Test/local adapter. It deliberately has no persistence and is never selected when DATABASE_URL is set. */
export class MemoryRepository implements LedgerRepository {
  private profiles = new Map<UUID, Profile>();
  private avatars = new Map<UUID, ImageRecord>();
  private groups = new Map<UUID, Group>();
  private memberships = new Map<UUID, Map<UUID, "owner" | "member">>();
  private receipts = new Map<UUID, ImageRecord>();
  private expenses = new Map<UUID, Expense[]>();
  private payments = new Map<UUID, Payment[]>();
  private requests = new Map<string, { fingerprint: string; value: Expense | Payment }>();

  async upsertProfile(userId: UUID, displayName: string): Promise<Profile> {
    const trimmed = displayName.trim();
    if (!trimmed || trimmed.length > 100) throw new ApiError(400, "displayName must contain 1–100 characters", "invalid_input");
    const profile = { id: userId, displayName: trimmed };
    this.profiles.set(userId, profile);
    return profile;
  }

  async putAvatar(userId: UUID, contentType: string, bytes: Uint8Array): Promise<string> {
    this.requireProfile(userId);
    const etag = imageEtag(bytes);
    this.avatars.set(userId, { contentType, bytes: Uint8Array.from(bytes), etag });
    return etag;
  }

  async getAvatar(requesterId: UUID, userId: UUID): Promise<StoredImage | null> {
    if (requesterId !== userId && !this.shareGroup(requesterId, userId)) throw new ApiError(403, "avatar is not visible to this user", "forbidden");
    return this.avatars.get(userId) ?? null;
  }

  async createGroup(actorId: UUID, name: string, currency: string): Promise<Group> {
    this.requireProfile(actorId);
    const trimmed = name.trim();
    if (!trimmed || trimmed.length > 100) throw new ApiError(400, "group name must contain 1–100 characters", "invalid_input");
    const group = { id: randomUUID(), name: trimmed, currency, version: 0 };
    this.groups.set(group.id, group);
    this.memberships.set(group.id, new Map([[actorId, "owner"]]));
    this.expenses.set(group.id, []);
    this.payments.set(group.id, []);
    return structuredClone(group);
  }

  async addMember(actorId: UUID, groupId: UUID, userId: UUID): Promise<void> {
    const members = this.requireGroup(groupId);
    if (members.get(actorId) !== "owner") throw new ApiError(403, "only a group owner can add members", "forbidden");
    this.requireProfile(userId);
    members.set(userId, "member");
  }

  async createReceipt(actorId: UUID, groupId: UUID, contentType: string, bytes: Uint8Array): Promise<UUID> {
    this.requireMember(actorId, groupId);
    const id = randomUUID();
    this.receipts.set(id, { groupId, contentType, bytes: Uint8Array.from(bytes), etag: imageEtag(bytes) });
    return id;
  }

  async getReceipt(actorId: UUID, receiptId: UUID): Promise<StoredImage | null> {
    const receipt = this.receipts.get(receiptId);
    if (!receipt) return null;
    this.requireMember(actorId, receipt.groupId!);
    return receipt;
  }

  async createExpense(actorId: UUID, groupId: UUID, input: CreateExpenseInput): Promise<Expense> {
    this.requireMember(actorId, groupId);
    const totalCents = validateExpense(input);
    const group = this.groups.get(groupId)!;
    if (group.currency !== input.currency) throw new ApiError(422, "expense currency must match the group currency", "currency_mismatch");
    this.requireMember(input.payerId, groupId);
    for (const allocation of input.allocations) this.requireMember(allocation.userId, groupId);
    if (input.receiptId) {
      const receipt = this.receipts.get(input.receiptId);
      if (!receipt || receipt.groupId !== groupId) throw new ApiError(400, "receipt does not belong to this group", "invalid_receipt");
    }

    const key = `expense:${actorId}:${input.clientRequestId}`;
    const existing = this.requests.get(key);
    const requestFingerprint = fingerprint(input);
    if (existing) {
      if (existing.value.groupId !== groupId) throw new ApiError(409, "clientRequestId was already used in another group", "idempotency_conflict");
      if (existing.fingerprint !== requestFingerprint) throw new ApiError(409, "clientRequestId was already used with different data", "idempotency_conflict");
      return structuredClone(existing.value as Expense);
    }
    const expense: Expense = {
      ...structuredClone(input), id: randomUUID(), groupId, creatorId: actorId, totalCents, createdAt: new Date().toISOString(),
    };
    this.expenses.get(groupId)!.push(expense);
    group.version += 1;
    this.requests.set(key, { fingerprint: requestFingerprint, value: expense });
    return structuredClone(expense);
  }

  async createPayment(actorId: UUID, groupId: UUID, input: CreatePaymentInput): Promise<Payment> {
    this.requireMember(actorId, groupId);
    validatePayment(input);
    this.requireMember(input.fromUserId, groupId);
    this.requireMember(input.toUserId, groupId);
    const key = `payment:${actorId}:${input.clientRequestId}`;
    const existing = this.requests.get(key);
    const requestFingerprint = fingerprint(input);
    if (existing) {
      if (existing.value.groupId !== groupId) throw new ApiError(409, "clientRequestId was already used in another group", "idempotency_conflict");
      if (existing.fingerprint !== requestFingerprint) throw new ApiError(409, "clientRequestId was already used with different data", "idempotency_conflict");
      return structuredClone(existing.value as Payment);
    }
    const payment: Payment = {
      ...structuredClone(input), id: randomUUID(), groupId, recorderId: actorId, createdAt: new Date().toISOString(),
    };
    this.payments.get(groupId)!.push(payment);
    this.groups.get(groupId)!.version += 1;
    this.requests.set(key, { fingerprint: requestFingerprint, value: payment });
    return structuredClone(payment);
  }

  async getSnapshot(actorId: UUID, groupId: UUID): Promise<GroupSnapshot> {
    const members = this.requireMember(actorId, groupId);
    const profiles = [...members.keys()].map((id) => this.requireProfile(id));
    const expenses = structuredClone(this.expenses.get(groupId) ?? []);
    const payments = structuredClone(this.payments.get(groupId) ?? []);
    return {
      group: structuredClone(this.groups.get(groupId)!), members: profiles, expenses, payments,
      balances: calculateBalances(profiles.map((profile) => profile.id), expenses, payments),
    };
  }

  private requireProfile(userId: UUID): Profile {
    const profile = this.profiles.get(userId);
    if (!profile) throw new ApiError(404, "profile not found", "not_found");
    return profile;
  }

  private requireGroup(groupId: UUID): Map<UUID, "owner" | "member"> {
    const members = this.memberships.get(groupId);
    if (!members) throw new ApiError(404, "group not found", "not_found");
    return members;
  }

  private requireMember(userId: UUID, groupId: UUID): Map<UUID, "owner" | "member"> {
    const members = this.requireGroup(groupId);
    if (!members.has(userId)) throw new ApiError(403, "user is not an active member of this group", "forbidden");
    return members;
  }

  private shareGroup(first: UUID, second: UUID): boolean {
    return [...this.memberships.values()].some((members) => members.has(first) && members.has(second));
  }
}
