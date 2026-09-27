import postgres from "postgres";
import { calculateBalances, filterTransactions, fingerprint, imageEtag, searchTerm, validateExpense, validatePayment } from "./domain.ts";
import type { AllocationInput, CreateExpenseInput, CreatePaymentInput, EvidenceAsset, EvidenceKind, Expense, ExpenseItemInput, FriendConnection, LedgerPerson, LedgerRepository, LedgerSnapshot, Payment, Profile, ProfileIdentity, SavedFilter, StoredImage, UserSearchResult, UUID } from "./types.ts";
import { ApiError } from "./types.ts";

export class PostgresRepository implements LedgerRepository {
  private readonly sql: ReturnType<typeof postgres>;
  constructor(databaseUrl: string) { this.sql = postgres(databaseUrl, { max: 1, prepare: false, ssl: "require", idle_timeout: 20, connect_timeout: 10 }); }
  async close(): Promise<void> { await this.sql.end(); }
  async checkHealth(): Promise<void> { await this.sql`SELECT 1`; }

  async updateIdentity(userId: UUID, firstName: string, lastName: string, username: string): Promise<ProfileIdentity> {
    const first = validName(firstName, "firstName"), last = validName(lastName, "lastName"), handle = validUsername(username);
    try {
      const rows = await this.sql`UPDATE user_profiles SET first_name=${first}, last_name=${last}, username=${handle}, updated_at=now() WHERE id=${userId} RETURNING id, first_name, last_name, username, display_name`;
      if (!rows.length) throw new ApiError(404, "profile not found", "not_found");
      const row = rows[0]!; return { id: row.id, firstName: row.first_name, lastName: row.last_name, username: row.username, displayName: row.display_name };
    } catch (error) { if (isUniqueError(error)) throw new ApiError(409, "username is already taken", "username_taken"); throw error; }
  }

  async searchUsers(userId: UUID, query: string): Promise<UserSearchResult[]> {
    const prefix = `${searchTerm(query).replace(/[\\%_]/g, "\\$&")}%`;
    const rows = await this.sql`
      SELECT p.id, p.display_name, p.username, p.avatar_etag, f.id request_id, f.status, f.requester_id
      FROM user_profiles p
      LEFT JOIN friend_requests f ON f.pair_low=least(p.id, ${userId}::uuid) AND f.pair_high=greatest(p.id, ${userId}::uuid)
      WHERE p.id<>${userId} AND p.username IS NOT NULL
        AND (p.username ILIKE ${prefix} OR p.first_name ILIKE ${prefix} OR p.last_name ILIKE ${prefix} OR p.display_name ILIKE ${prefix})
      ORDER BY p.display_name, p.username LIMIT 20`;
    return rows.map((row) => {
      const relationship = !row.request_id ? "none" : row.status === "accepted" ? "friend" : row.requester_id === userId ? "outgoing" : "incoming";
      const result: UserSearchResult = { userId: row.id, displayName: row.display_name, username: row.username, hasAvatar: row.avatar_etag !== null, avatarEtag: row.avatar_etag, relationship };
      if (row.request_id) result.requestId = row.request_id;
      return result;
    });
  }

  async listFriends(userId: UUID): Promise<FriendConnection[]> {
    const rows = await this.sql`SELECT f.id request_id, f.status, CASE WHEN f.requester_id=${userId} THEN f.addressee_id ELSE f.requester_id END user_id, CASE WHEN f.requester_id=${userId} THEN 'outgoing' ELSE 'incoming' END direction, p.display_name, p.username, p.avatar_etag FROM friend_requests f JOIN user_profiles p ON p.id=CASE WHEN f.requester_id=${userId} THEN f.addressee_id ELSE f.requester_id END WHERE f.requester_id=${userId} OR f.addressee_id=${userId} ORDER BY f.status, p.display_name`;
    return rows.map((row) => mapFriend(row, row.status === "accepted" ? "friend" : row.direction));
  }

  async requestFriend(userId: UUID, username: string): Promise<FriendConnection> {
    const handle = validUsername(username);
    const [me] = await this.sql`SELECT username FROM user_profiles WHERE id=${userId}`;
    if (!me?.username) throw new ApiError(409, "add your name and username before inviting friends", "profile_incomplete");
    const targets = await this.sql`SELECT id, display_name, username, avatar_etag FROM user_profiles WHERE lower(username)=lower(${handle})`;
    if (!targets.length) throw new ApiError(404, "username not found", "not_found");
    const target = targets[0]!;
    if (target.id === userId) throw new ApiError(400, "you cannot invite yourself", "invalid_input");
    try {
      const [row] = await this.sql`INSERT INTO friend_requests (requester_id, addressee_id) VALUES (${userId}, ${target.id}) RETURNING id, status`;
      return { requestId: row!.id, userId: target.id, displayName: target.display_name, username: target.username, avatarEtag: target.avatar_etag, status: "pending", direction: "outgoing" };
    } catch (error) { if (isUniqueError(error)) throw new ApiError(409, "a friendship or request already exists", "friend_exists"); throw error; }
  }

  async acceptFriend(userId: UUID, requestId: UUID): Promise<FriendConnection> {
    const rows = await this.sql`
      UPDATE friend_requests f SET status='accepted', responded_at=now() FROM user_profiles p
      WHERE f.id=${requestId} AND f.addressee_id=${userId} AND f.status='pending' AND p.id=f.requester_id
      RETURNING f.requester_id, p.display_name, p.username, p.avatar_etag`;
    if (!rows.length) throw new ApiError(404, "pending friend request not found", "not_found");
    const friend = rows[0]!;
    return { requestId, userId: friend.requester_id, displayName: friend.display_name, username: friend.username, avatarEtag: friend.avatar_etag, status: "accepted", direction: "friend" };
  }

  async removeFriend(userId: UUID, friendId: UUID): Promise<void> {
    const rows = await this.sql`DELETE FROM friend_requests WHERE pair_low=least(${userId}::uuid, ${friendId}::uuid) AND pair_high=greatest(${userId}::uuid, ${friendId}::uuid) RETURNING id`;
    if (!rows.length) throw new ApiError(404, "friend not found", "not_found");
  }

  async ensureProfile(userId: UUID): Promise<Profile> {
    return this.sql.begin(async (tx) => {
      const [row] = await tx`INSERT INTO user_profiles (id) VALUES (${userId}) ON CONFLICT (id) DO UPDATE SET id=EXCLUDED.id RETURNING id, first_name, last_name, username, display_name`;
      await tx`INSERT INTO ledgers (owner_id, currency) VALUES (${userId}, 'USD') ON CONFLICT (owner_id) DO NOTHING`;
      return mapProfile(row!);
    });
  }
  async getProfile(userId: UUID): Promise<Profile> {
    const rows = await this.sql`SELECT id, first_name, last_name, username, display_name FROM user_profiles WHERE id=${userId}`;
    if (!rows.length) throw new ApiError(404, "profile not found", "not_found");
    return mapProfile(rows[0]!);
  }

  async putAvatar(userId: UUID, contentType: string, bytes: Uint8Array): Promise<string> {
    const etag = imageEtag(bytes), rows = await this.sql`UPDATE user_profiles SET avatar_content_type=${contentType}, avatar_data=${bytes}, avatar_etag=${etag}, avatar_updated_at=now(), updated_at=now() WHERE id=${userId} RETURNING id`;
    if (!rows.length) throw new ApiError(404, "profile not found", "not_found"); return etag;
  }
  async getAvatar(requesterId: UUID, userId: UUID): Promise<StoredImage | null> {
    const rows = await this.sql`SELECT avatar_content_type, avatar_data, avatar_etag FROM user_profiles p WHERE p.id=${userId} AND p.avatar_data IS NOT NULL AND (p.id=${requesterId} OR p.username IS NOT NULL)`;
    if (!rows.length) return null; const row = rows[0]!; return { contentType: row.avatar_content_type, bytes: toBytes(row.avatar_data), etag: row.avatar_etag };
  }

  async createSavedFilter(ownerId: UUID, name: string, userIds: UUID[]): Promise<SavedFilter> {
    if (!userIds.length || new Set(userIds).size !== userIds.length || userIds.length > 100) throw new ApiError(400, "userIds must contain 1–100 unique people", "invalid_input");
    return this.sql.begin(async (tx) => {
      await requireFriends(tx, ownerId, userIds);
      const [row] = await tx`INSERT INTO saved_filters (owner_id, name) VALUES (${ownerId}, ${validName(name, "filter name")}) RETURNING *`;
      for (const userId of userIds) await tx`INSERT INTO saved_filter_members (owner_id, filter_id, user_id) VALUES (${ownerId}, ${row!.id}, ${userId})`;
      return { id: row!.id, name: row!.name, userIds: [...userIds], createdAt: toIso(row!.created_at) };
    });
  }
  async listSavedFilters(ownerId: UUID): Promise<SavedFilter[]> {
    const [filters, members] = await Promise.all([this.sql`SELECT * FROM saved_filters WHERE owner_id=${ownerId} ORDER BY name, id`, this.sql`SELECT filter_id, user_id FROM saved_filter_members WHERE owner_id=${ownerId} ORDER BY filter_id, user_id`]);
    return filters.map((row) => ({ id: row.id, name: row.name, userIds: members.filter((m) => m.filter_id === row.id).map((m) => m.user_id), createdAt: toIso(row.created_at) }));
  }

  async createEvidence(uploaderId: UUID, kind: EvidenceKind, contentType: string, bytes: Uint8Array): Promise<EvidenceAsset> {
    const etag = imageEtag(bytes);
    const [row] = await this.sql`INSERT INTO evidence_assets (uploaded_by, kind, content_type, image_data, image_etag) VALUES (${uploaderId}, ${kind}, ${contentType}, ${bytes}, ${etag}) RETURNING *`;
    return { id: row!.id, kind: row!.kind, contentType: row!.content_type, etag: row!.image_etag, createdAt: toIso(row!.created_at) };
  }
  async getEvidence(requesterId: UUID, evidenceId: UUID): Promise<StoredImage | null> {
    const rows = await this.sql`
      SELECT a.content_type, a.image_data, a.image_etag FROM evidence_assets a
      WHERE a.id=${evidenceId} AND (a.uploaded_by=${requesterId} OR EXISTS (
        SELECT 1 FROM expense_evidence ee JOIN expenses e ON e.id=ee.expense_id
        WHERE ee.evidence_id=a.id AND ${visibleTo(this.sql, requesterId)}))`;
    if (!rows.length) return null; return { contentType: rows[0]!.content_type, bytes: toBytes(rows[0]!.image_data), etag: rows[0]!.image_etag };
  }
  async putEvidenceText(uploaderId: UUID, evidenceId: UUID, text: string): Promise<boolean> {
    const rows = await this.sql`UPDATE evidence_assets SET extraction_status='complete', extracted_data=${this.sql.json({ source: "device", text })} WHERE id=${evidenceId} AND uploaded_by=${uploaderId} RETURNING id`;
    return rows.length > 0;
  }

  async createExpense(creatorId: UUID, input: CreateExpenseInput): Promise<Expense> {
    validateExpense(input); const requestFingerprint = fingerprint(input);
    return this.sql.begin(async (tx) => {
      await tx`SELECT pg_advisory_xact_lock(hashtextextended(${`expense:${creatorId}:${input.clientRequestId}`}, 0))`;
      const prior = await tx`SELECT * FROM expenses WHERE creator_id=${creatorId} AND client_request_id=${input.clientRequestId}`;
      if (prior.length) { if (prior[0]!.request_fingerprint !== requestFingerprint) throw new ApiError(409, "clientRequestId was already used with different data", "idempotency_conflict"); return this.loadExpense(tx, prior[0]!); }
      const ledgers = await tx`SELECT currency FROM ledgers WHERE owner_id=${creatorId}`;
      if (!ledgers.length) throw new ApiError(404, "profile not found", "not_found");
      if (ledgers[0]!.currency !== input.currency) throw new ApiError(422, "expense currency must match the ledger currency", "currency_mismatch");
      await requireFriends(tx, creatorId, [input.payerId, ...input.allocations.map((a) => a.userId)]);
      const evidenceIds = input.evidenceIds ?? [];
      if (evidenceIds.length && (await tx`SELECT id FROM evidence_assets WHERE uploaded_by=${creatorId} AND id IN ${tx(evidenceIds)}`).length !== evidenceIds.length) throw new ApiError(400, "evidence was not uploaded by you", "invalid_evidence");
      const [row] = await tx`INSERT INTO expenses (creator_id, payer_id, client_request_id, request_fingerprint, description, currency, total_cents, transaction_date) VALUES (${creatorId}, ${input.payerId}, ${input.clientRequestId}, ${requestFingerprint}, ${input.description.trim()}, ${input.currency}, ${input.totalCents}, ${input.transactionDate}) RETURNING *`;
      for (const [position, item] of (input.items ?? []).entries()) await tx`INSERT INTO expense_items (expense_id, position, name, amount_cents, offset_cents) VALUES (${row!.id}, ${position}, ${item.name.trim()}, ${item.amountCents}, ${item.offsetCents ?? 0})`;
      for (const allocation of input.allocations) await tx`INSERT INTO expense_allocations (expense_id, user_id, amount_cents) VALUES (${row!.id}, ${allocation.userId}, ${allocation.amountCents})`;
      for (const [position, evidenceId] of evidenceIds.entries()) await tx`INSERT INTO expense_evidence (expense_id, evidence_id, position) VALUES (${row!.id}, ${evidenceId}, ${position})`;
      await tx`INSERT INTO audit_events (actor_id, event_type, entity_id) VALUES (${creatorId}, 'expense.created', ${row!.id})`;
      return mapExpense(row!, input.items ?? [], input.allocations, evidenceIds);
    });
  }

  async createPayment(recorderId: UUID, input: CreatePaymentInput): Promise<Payment> {
    validatePayment(recorderId, input); const requestFingerprint = fingerprint(input);
    const otherId = input.fromUserId === recorderId ? input.toUserId : input.fromUserId;
    return this.sql.begin(async (tx) => {
      await tx`SELECT pg_advisory_xact_lock(hashtextextended(${`payment:${recorderId}:${input.clientRequestId}`}, 0))`;
      const prior = await tx`SELECT * FROM repayments WHERE recorder_id=${recorderId} AND client_request_id=${input.clientRequestId}`;
      if (prior.length) { if (prior[0]!.request_fingerprint !== requestFingerprint) throw new ApiError(409, "clientRequestId was already used with different data", "idempotency_conflict"); return mapPayment(prior[0]!); }
      // Settling up stays possible with someone you've shared an expense with, even after unfriending them.
      const [link] = await tx`
        SELECT EXISTS (SELECT 1 FROM friend_requests WHERE status='accepted' AND pair_low=least(${recorderId}::uuid, ${otherId}::uuid) AND pair_high=greatest(${recorderId}::uuid, ${otherId}::uuid))
          OR EXISTS (SELECT 1 FROM expenses e JOIN expense_allocations a ON a.expense_id=e.id WHERE e.status='active'
            AND ((e.payer_id=${recorderId} AND a.user_id=${otherId}) OR (e.payer_id=${otherId} AND a.user_id=${recorderId}))) linked`;
      if (!link!.linked) throw new ApiError(422, "you can only record payments with friends or people you've shared expenses with", "invalid_person");
      const [row] = await tx`INSERT INTO repayments (recorder_id, from_user_id, to_user_id, client_request_id, request_fingerprint, amount_cents, transaction_date) VALUES (${recorderId}, ${input.fromUserId}, ${input.toUserId}, ${input.clientRequestId}, ${requestFingerprint}, ${input.amountCents}, ${input.transactionDate}) RETURNING *`;
      await tx`INSERT INTO audit_events (actor_id, event_type, entity_id) VALUES (${recorderId}, 'repayment.created', ${row!.id})`;
      return mapPayment(row!);
    });
  }

  async getSnapshot(userId: UUID, filterId?: UUID): Promise<LedgerSnapshot> {
    const visibleIds = this.sql`SELECT e.id FROM expenses e WHERE e.status='active' AND ${visibleTo(this.sql, userId)}`;
    const [ledgers, savedFilters, expenseRows, itemRows, allocationRows, evidenceRows, paymentRows, friendRows] = await Promise.all([
      this.sql`SELECT currency FROM ledgers WHERE owner_id=${userId}`, this.listSavedFilters(userId),
      this.sql`SELECT * FROM expenses WHERE id IN (${visibleIds}) ORDER BY transaction_date DESC, created_at DESC, id`,
      this.sql`SELECT * FROM expense_items WHERE expense_id IN (${visibleIds}) ORDER BY expense_id, position`,
      this.sql`SELECT * FROM expense_allocations WHERE expense_id IN (${visibleIds}) ORDER BY expense_id, user_id`,
      this.sql`SELECT * FROM expense_evidence WHERE expense_id IN (${visibleIds}) ORDER BY expense_id, position`,
      this.sql`SELECT * FROM repayments WHERE status='active' AND (from_user_id=${userId} OR to_user_id=${userId}) ORDER BY transaction_date DESC, created_at DESC, id`,
      this.sql`SELECT CASE WHEN requester_id=${userId} THEN addressee_id ELSE requester_id END user_id FROM friend_requests WHERE status='accepted' AND (requester_id=${userId} OR addressee_id=${userId})`]);
    if (!ledgers.length) throw new ApiError(404, "profile not found", "not_found");
    let expenses = expenseRows.map((row) => mapExpense(row, itemRows.filter((i) => i.expense_id === row.id).map(mapItem), allocationRows.filter((a) => a.expense_id === row.id).map(mapAllocation), evidenceRows.filter((e) => e.expense_id === row.id).map((e) => e.evidence_id)));
    let payments = paymentRows.map(mapPayment);
    const balances = calculateBalances(userId, expenses, payments);
    const peopleIds = new Set<UUID>([userId, ...friendRows.map((row) => row.user_id as UUID)]);
    for (const expense of expenses) { peopleIds.add(expense.creatorId); peopleIds.add(expense.payerId); expense.allocations.forEach((a) => peopleIds.add(a.userId)); }
    for (const payment of payments) { peopleIds.add(payment.fromUserId); peopleIds.add(payment.toUserId); }
    const people = (await this.sql`SELECT id, display_name, username, avatar_etag FROM user_profiles WHERE id IN ${this.sql([...peopleIds])} ORDER BY display_name, id`).map(mapLedgerPerson);
    if (filterId) {
      const filter = savedFilters.find((f) => f.id === filterId);
      if (!filter) throw new ApiError(404, "saved filter not found", "not_found");
      ({ expenses, payments } = filterTransactions(filter.userIds, expenses, payments));
    }
    const result: LedgerSnapshot = { currency: ledgers[0]!.currency, people, savedFilters, expenses, payments, balances, netBalance: Object.values(balances).reduce((sum, value) => sum + value, 0) };
    if (filterId) result.appliedFilterId = filterId; return result;
  }

  private async loadExpense(sql: any, row: any): Promise<Expense> {
    const [items, allocations, evidence] = await Promise.all([sql`SELECT * FROM expense_items WHERE expense_id=${row.id} ORDER BY position`, sql`SELECT * FROM expense_allocations WHERE expense_id=${row.id} ORDER BY user_id`, sql`SELECT evidence_id FROM expense_evidence WHERE expense_id=${row.id} ORDER BY position`]);
    return mapExpense(row, items.map(mapItem), allocations.map(mapAllocation), evidence.map((e: any) => e.evidence_id));
  }
}

/** SQL condition on an expense aliased `e`: the user created it, paid it, or has a share of it. */
function visibleTo(sql: any, userId: UUID) {
  return sql`(e.creator_id=${userId} OR e.payer_id=${userId} OR EXISTS (SELECT 1 FROM expense_allocations x WHERE x.expense_id=e.id AND x.user_id=${userId}))`;
}

/** Everyone other than `userId` in `ids` must be one of their accepted friends. */
async function requireFriends(sql: any, userId: UUID, ids: UUID[]): Promise<void> {
  const others = [...new Set(ids)].filter((id) => id !== userId);
  if (!others.length) return;
  const rows = await sql`SELECT 1 FROM friend_requests WHERE status='accepted' AND ((requester_id=${userId} AND addressee_id IN ${sql(others)}) OR (addressee_id=${userId} AND requester_id IN ${sql(others)}))`;
  if (rows.length !== others.length) throw new ApiError(422, "you can only split with yourself and your friends", "invalid_person");
}

function mapProfile(row: any): Profile { return { id: row.id, firstName: row.first_name, lastName: row.last_name, username: row.username, displayName: row.display_name }; }
function mapLedgerPerson(row: any): LedgerPerson { return { userId: row.id, displayName: row.display_name, username: row.username, avatarEtag: row.avatar_etag }; }
function mapItem(row: any): ExpenseItemInput { return { name: row.name, amountCents: Number(row.amount_cents), offsetCents: Number(row.offset_cents) }; }
function mapAllocation(row: any): AllocationInput { return { userId: row.user_id, amountCents: Number(row.amount_cents) }; }
function mapExpense(row: any, items: ExpenseItemInput[], allocations: AllocationInput[], evidenceIds: UUID[]): Expense { return { id: row.id, creatorId: row.creator_id, clientRequestId: row.client_request_id, description: row.description, transactionDate: toDay(row.transaction_date), payerId: row.payer_id, currency: row.currency, totalCents: Number(row.total_cents), items, allocations, evidenceIds, createdAt: toIso(row.created_at) }; }
function mapPayment(row: any): Payment { return { id: row.id, recorderId: row.recorder_id, clientRequestId: row.client_request_id, fromUserId: row.from_user_id, toUserId: row.to_user_id, amountCents: Number(row.amount_cents), transactionDate: toDay(row.transaction_date), createdAt: toIso(row.created_at) }; }
function mapFriend(row: any, direction: FriendConnection["direction"]): FriendConnection { return { requestId: row.request_id, userId: row.user_id, displayName: row.display_name, username: row.username, avatarEtag: row.avatar_etag, status: row.status, direction }; }
function toBytes(value: unknown): Uint8Array { if (value instanceof Uint8Array) return value; throw new Error("PostgreSQL returned an unexpected bytea value"); }
function toIso(value: unknown): string { return value instanceof Date ? value.toISOString() : String(value); }
/** The driver parses `date` columns as midnight UTC; return the YYYY-MM-DD the API promises. */
function toDay(value: unknown): string { return value instanceof Date ? value.toISOString().slice(0, 10) : String(value); }
function isUniqueError(error: unknown): boolean { return typeof error === "object" && error !== null && "code" in error && (error as { code?: string }).code === "23505"; }
function validName(value: string, field: string): string { const trimmed = value.trim(); if (!trimmed || trimmed.length > 100) throw new ApiError(400, `${field} must contain 1–100 characters`, "invalid_input"); return trimmed; }
function validUsername(value: string): string { const username = value.trim().toLowerCase(); if (!/^[a-z0-9_]{3,24}$/.test(username)) throw new ApiError(400, "username must be 3–24 lowercase letters, numbers, or underscores", "invalid_input"); return username; }
