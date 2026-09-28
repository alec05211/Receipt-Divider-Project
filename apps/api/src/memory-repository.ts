import { randomUUID } from "node:crypto";
import { calculateBalances, filterTransactions, fingerprint, imageEtag, searchTerm, validateExpenseChanges, validateExpense, validatePayment } from "./domain.ts";
import type { CreateExpenseInput, CreatePaymentInput, EvidenceAsset, EvidenceKind, Expense, ExpenseChanges, FriendConnection, LedgerPerson, LedgerRepository, LedgerSnapshot, Payment, Profile, ProfileIdentity, Relationship, SavedFilter, StoredImage, UserSearchResult, UUID } from "./types.ts";
import { ApiError } from "./types.ts";

interface ImageRecord extends StoredImage { ownerId: UUID; kind?: EvidenceKind; createdAt?: string; text?: string; }
interface FriendRequest { id: UUID; requesterId: UUID; addresseeId: UUID; status: "pending" | "accepted"; }

/** Test/local adapter. It deliberately has no persistence and is never selected when DATABASE_URL is set. */
export class MemoryRepository implements LedgerRepository {
  private profiles = new Map<UUID, Profile>();
  private currencies = new Map<UUID, string>();
  private avatars = new Map<UUID, ImageRecord>();
  private filters = new Map<UUID, SavedFilter[]>();
  private evidence = new Map<UUID, ImageRecord>();
  private expenses: Expense[] = [];
  private payments: Payment[] = [];
  private requests = new Map<string, { fingerprint: string; value: Expense | Payment }>();
  private friendRequests: FriendRequest[] = [];
  /** Revisions, recorded like the database's audit events so tests can check them. */
  readonly auditEvents: Array<{ actorId: UUID; eventType: string; entityId: UUID; details: Record<string, unknown> }> = [];

  /** `developerIds` stands in for the database's developer flag. */
  constructor(private readonly developerIds: ReadonlySet<UUID> = new Set()) {}

  async checkHealth(): Promise<void> {}

  async updateIdentity(userId: UUID, firstName: string, lastName: string, username: string): Promise<ProfileIdentity> {
    this.requireProfile(userId);
    const handle = username.trim().toLowerCase();
    if ([...this.profiles.values()].some((profile) => profile.id !== userId && profile.username === handle)) throw new ApiError(409, "username is already taken", "username_taken");
    const identity = { id: userId, firstName: firstName.trim(), lastName: lastName.trim(), username: handle, displayName: `${firstName.trim()} ${lastName.trim()}` };
    this.profiles.set(userId, { ...identity, isDeveloper: false }); return identity;
  }
  async searchUsers(userId: UUID, query: string): Promise<UserSearchResult[]> {
    const term = searchTerm(query).toLowerCase();
    return [...this.profiles.values()]
      .filter((profile): profile is Profile & ProfileIdentity => profile.id !== userId && profile.username !== null)
      .filter((profile) => [profile.username, profile.firstName, profile.lastName, profile.displayName].some((field) => field.toLowerCase().startsWith(term)))
      .sort((left, right) => left.displayName.localeCompare(right.displayName))
      .slice(0, 20)
      .map((profile) => {
        const request = this.requestBetween(userId, profile.id);
        const relationship: Relationship = !request ? "none" : request.status === "accepted" ? "friend" : request.requesterId === userId ? "outgoing" : "incoming";
        const result: UserSearchResult = { userId: profile.id, displayName: profile.displayName, username: profile.username, hasAvatar: this.avatars.has(profile.id), avatarEtag: this.avatarEtag(profile.id), relationship };
        if (request) result.requestId = request.id;
        return result;
      });
  }
  async listFriends(userId: UUID): Promise<FriendConnection[]> {
    return this.friendRequests.filter((request) => request.requesterId === userId || request.addresseeId === userId).map((request) => {
      const otherId = request.requesterId === userId ? request.addresseeId : request.requesterId;
      return this.connection(request, otherId, request.status === "accepted" ? "friend" : request.requesterId === userId ? "outgoing" : "incoming");
    });
  }
  async requestFriend(userId: UUID, username: string): Promise<FriendConnection> {
    if (!this.requireProfile(userId).username) throw new ApiError(409, "add your name and username before inviting friends", "profile_incomplete");
    const target = [...this.profiles.values()].find((profile) => profile.username === username.trim().toLowerCase());
    if (!target) throw new ApiError(404, "username not found", "not_found");
    if (target.id === userId) throw new ApiError(400, "you cannot invite yourself", "invalid_input");
    if (this.requestBetween(userId, target.id)) throw new ApiError(409, "a friendship or request already exists", "friend_exists");
    const request: FriendRequest = { id: randomUUID(), requesterId: userId, addresseeId: target.id, status: "pending" };
    this.friendRequests.push(request);
    return this.connection(request, target.id, "outgoing");
  }
  async acceptFriend(userId: UUID, requestId: UUID): Promise<FriendConnection> {
    const request = this.friendRequests.find((item) => item.id === requestId && item.addresseeId === userId && item.status === "pending");
    if (!request) throw new ApiError(404, "pending friend request not found", "not_found");
    request.status = "accepted";
    return this.connection(request, request.requesterId, "friend");
  }
  async removeFriend(userId: UUID, friendId: UUID): Promise<void> {
    const request = this.requestBetween(userId, friendId);
    if (!request) throw new ApiError(404, "friend not found", "not_found");
    this.friendRequests = this.friendRequests.filter((item) => item !== request);
  }

  async ensureProfile(userId: UUID): Promise<Profile> {
    const profile = this.profiles.get(userId) ?? { id: userId, firstName: null, lastName: null, username: null, displayName: null, isDeveloper: false };
    this.profiles.set(userId, profile);
    if (!this.currencies.has(userId)) { this.currencies.set(userId, "USD"); this.filters.set(userId, []); }
    return { ...profile, isDeveloper: this.developerIds.has(userId) };
  }
  async getProfile(userId: UUID): Promise<Profile> { return { ...this.requireProfile(userId), isDeveloper: this.developerIds.has(userId) }; }
  async resetLedgerData(userId: UUID): Promise<void> {
    this.requireProfile(userId);
    if (!this.developerIds.has(userId)) throw new ApiError(403, "developer access is required", "forbidden");
    this.evidence.clear(); this.expenses = []; this.payments = []; this.requests.clear(); this.auditEvents.length = 0;
  }

  async putAvatar(userId: UUID, contentType: string, bytes: Uint8Array): Promise<string> {
    this.requireProfile(userId);
    const etag = imageEtag(bytes);
    this.avatars.set(userId, { ownerId: userId, contentType, bytes: Uint8Array.from(bytes), etag });
    return etag;
  }
  async getAvatar(requesterId: UUID, userId: UUID): Promise<StoredImage | null> {
    this.requireProfile(requesterId);
    if (requesterId !== userId && !this.profiles.get(userId)?.username) return null;
    return this.avatars.get(userId) ?? null;
  }

  async createSavedFilter(ownerId: UUID, name: string, userIds: UUID[]): Promise<SavedFilter> {
    this.requireProfile(ownerId);
    if (!userIds.length || new Set(userIds).size !== userIds.length || userIds.length > 100) throw new ApiError(400, "userIds must contain 1–100 unique people", "invalid_input");
    this.requireFriends(ownerId, userIds);
    const filter = { id: randomUUID(), name: validName(name, "filter name"), userIds: [...userIds], createdAt: new Date().toISOString() };
    this.filters.get(ownerId)!.push(filter);
    return structuredClone(filter);
  }
  async listSavedFilters(ownerId: UUID): Promise<SavedFilter[]> { this.requireProfile(ownerId); return structuredClone(this.filters.get(ownerId) ?? []); }

  async createEvidence(uploaderId: UUID, kind: EvidenceKind, contentType: string, bytes: Uint8Array): Promise<EvidenceAsset> {
    this.requireProfile(uploaderId);
    const id = randomUUID(), etag = imageEtag(bytes), createdAt = new Date().toISOString();
    this.evidence.set(id, { ownerId: uploaderId, kind, contentType, bytes: Uint8Array.from(bytes), etag, createdAt });
    return { id, kind, contentType, etag, createdAt };
  }
  async getEvidence(requesterId: UUID, evidenceId: UUID): Promise<StoredImage | null> {
    const image = this.evidence.get(evidenceId);
    if (!image) return null;
    const visible = image.ownerId === requesterId || this.visibleExpenses(requesterId).some((expense) => expense.evidenceIds.includes(evidenceId));
    return visible ? image : null;
  }
  async putEvidenceText(uploaderId: UUID, evidenceId: UUID, text: string): Promise<boolean> {
    const image = this.evidence.get(evidenceId);
    if (image?.ownerId !== uploaderId) return false;
    image.text = text; return true;
  }

  async createExpense(creatorId: UUID, input: CreateExpenseInput): Promise<Expense> {
    this.requireProfile(creatorId); validateExpense(input);
    if (this.currencies.get(creatorId) !== input.currency) throw new ApiError(422, "expense currency must match the ledger currency", "currency_mismatch");
    this.requireFriends(creatorId, [input.payerId, ...input.allocations.map((allocation) => allocation.userId)]);
    for (const evidenceId of input.evidenceIds ?? []) {
      if (this.evidence.get(evidenceId)?.ownerId !== creatorId) throw new ApiError(400, "evidence was not uploaded by you", "invalid_evidence");
    }
    const key = `expense:${creatorId}:${input.clientRequestId}`, requestFingerprint = fingerprint(input), existing = this.requests.get(key);
    if (existing) {
      if (existing.fingerprint !== requestFingerprint) throw new ApiError(409, "clientRequestId was already used with different data", "idempotency_conflict");
      return structuredClone(existing.value as Expense);
    }
    const expense: Expense = { ...structuredClone(input), category: input.category ?? null, items: structuredClone(input.items ?? []), evidenceIds: [...(input.evidenceIds ?? [])], id: randomUUID(), creatorId, createdAt: new Date().toISOString() };
    this.expenses.push(expense); this.requests.set(key, { fingerprint: requestFingerprint, value: expense });
    return structuredClone(expense);
  }

  async updateExpense(userId: UUID, expenseId: UUID, changes: ExpenseChanges): Promise<Expense> {
    const { description, transactionDate } = validateExpenseChanges(changes);
    const expense = this.visibleExpenses(userId).find((candidate) => candidate.id === expenseId);
    if (!expense) throw new ApiError(404, "expense not found", "not_found");
    if (expense.payerId !== userId) throw new ApiError(403, "only the payer can edit this expense", "forbidden");
    if (description !== undefined && expense.description !== description) {
      this.auditEvents.push({ actorId: userId, eventType: "expense.description_changed", entityId: expenseId, details: { from: expense.description, to: description } });
      expense.description = description;
    }
    if (transactionDate !== undefined && expense.transactionDate !== transactionDate) {
      this.auditEvents.push({ actorId: userId, eventType: "expense.date_changed", entityId: expenseId, details: { from: expense.transactionDate, to: transactionDate } });
      expense.transactionDate = transactionDate;
    }
    return structuredClone(expense);
  }

  async createPayment(recorderId: UUID, input: CreatePaymentInput): Promise<Payment> {
    this.requireProfile(recorderId); validatePayment(recorderId, input);
    const otherId = input.fromUserId === recorderId ? input.toUserId : input.fromUserId;
    const shared = this.expenses.some((expense) => expense.allocations.some((a) => (expense.payerId === recorderId && a.userId === otherId) || (expense.payerId === otherId && a.userId === recorderId)));
    if (!shared && this.requestBetween(recorderId, otherId)?.status !== "accepted") throw new ApiError(422, "you can only record payments with friends or people you've shared expenses with", "invalid_person");
    const key = `payment:${recorderId}:${input.clientRequestId}`, requestFingerprint = fingerprint(input), existing = this.requests.get(key);
    if (existing) {
      if (existing.fingerprint !== requestFingerprint) throw new ApiError(409, "clientRequestId was already used with different data", "idempotency_conflict");
      return structuredClone(existing.value as Payment);
    }
    const payment: Payment = { ...structuredClone(input), id: randomUUID(), recorderId, createdAt: new Date().toISOString() };
    this.payments.push(payment); this.requests.set(key, { fingerprint: requestFingerprint, value: payment });
    return structuredClone(payment);
  }

  async getSnapshot(userId: UUID, filterId?: UUID): Promise<LedgerSnapshot> {
    this.requireProfile(userId);
    const savedFilters = await this.listSavedFilters(userId);
    let expenses = structuredClone(this.visibleExpenses(userId));
    let payments = structuredClone(this.payments.filter((payment) => payment.fromUserId === userId || payment.toUserId === userId));
    const balances = calculateBalances(userId, expenses, payments);
    const peopleIds = new Set<UUID>([userId, ...this.friendIds(userId)]);
    for (const expense of expenses) { peopleIds.add(expense.creatorId); peopleIds.add(expense.payerId); expense.allocations.forEach((a) => peopleIds.add(a.userId)); }
    for (const payment of payments) { peopleIds.add(payment.fromUserId); peopleIds.add(payment.toUserId); }
    const people: LedgerPerson[] = [...peopleIds].map((id) => {
      const profile = this.requireProfile(id);
      return { userId: id, displayName: profile.displayName, username: profile.username, avatarEtag: this.avatarEtag(id) };
    });
    if (filterId) {
      const filter = savedFilters.find((item) => item.id === filterId);
      if (!filter) throw new ApiError(404, "saved filter not found", "not_found");
      ({ expenses, payments } = filterTransactions(filter.userIds, expenses, payments));
    }
    const snapshot: LedgerSnapshot = { currency: this.currencies.get(userId)!, people, savedFilters, expenses, payments, balances, netBalance: Object.values(balances).reduce((sum, value) => sum + value, 0) };
    if (filterId) snapshot.appliedFilterId = filterId;
    return snapshot;
  }

  private visibleExpenses(userId: UUID): Expense[] {
    return this.expenses.filter((expense) => expense.creatorId === userId || expense.payerId === userId || expense.allocations.some((a) => a.userId === userId));
  }
  private requestBetween(left: UUID, right: UUID): FriendRequest | undefined {
    return this.friendRequests.find((request) => (request.requesterId === left && request.addresseeId === right) || (request.requesterId === right && request.addresseeId === left));
  }
  private friendIds(userId: UUID): UUID[] {
    return this.friendRequests.filter((request) => request.status === "accepted" && (request.requesterId === userId || request.addresseeId === userId))
      .map((request) => request.requesterId === userId ? request.addresseeId : request.requesterId);
  }
  private requireFriends(userId: UUID, ids: UUID[]): void {
    const friends = new Set(this.friendIds(userId));
    if (ids.some((id) => id !== userId && !friends.has(id))) throw new ApiError(422, "you can only split with yourself and your friends", "invalid_person");
  }
  private connection(request: FriendRequest, otherId: UUID, direction: FriendConnection["direction"]): FriendConnection {
    const other = this.requireProfile(otherId);
    return { requestId: request.id, userId: otherId, displayName: other.displayName ?? "", username: other.username ?? "", avatarEtag: this.avatarEtag(otherId), status: request.status, direction };
  }
  private avatarEtag(userId: UUID): string | null { return this.avatars.get(userId)?.etag ?? null; }
  private requireProfile(userId: UUID): Profile { const profile = this.profiles.get(userId); if (!profile) throw new ApiError(404, "profile not found", "not_found"); return profile; }
}

function validName(value: string, field: string): string { const trimmed = value.trim(); if (!trimmed || trimmed.length > 100) throw new ApiError(400, `${field} must contain 1–100 characters`, "invalid_input"); return trimmed; }
