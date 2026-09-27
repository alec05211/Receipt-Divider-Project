import postgres from "postgres";
import { calculateBalances, fingerprint, imageEtag, searchTerm, validateExpense, validatePayment } from "./domain.ts";
import type { AllocationInput, CreateExpenseInput, CreatePaymentInput, EvidenceAsset, EvidenceKind, Expense, ExpenseItemInput, FriendConnection, LedgerRepository, LedgerSnapshot, Payment, Person, Profile, ProfileIdentity, SavedFilter, StoredImage, UserSearchResult, UUID } from "./types.ts";
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
      SELECT p.id, p.display_name, p.username, p.avatar_etag IS NOT NULL has_avatar, f.id request_id, f.status, f.requester_id
      FROM user_profiles p
      LEFT JOIN friend_requests f ON f.pair_low=least(p.id, ${userId}::uuid) AND f.pair_high=greatest(p.id, ${userId}::uuid)
      WHERE p.id<>${userId} AND p.username IS NOT NULL
        AND (p.username ILIKE ${prefix} OR p.first_name ILIKE ${prefix} OR p.last_name ILIKE ${prefix} OR p.display_name ILIKE ${prefix})
      ORDER BY p.display_name, p.username LIMIT 20`;
    return rows.map((row) => {
      const relationship = !row.request_id ? "none" : row.status === "accepted" ? "friend" : row.requester_id === userId ? "outgoing" : "incoming";
      const result: UserSearchResult = { userId: row.id, displayName: row.display_name, username: row.username, hasAvatar: row.has_avatar, relationship };
      if (row.request_id) result.requestId = row.request_id;
      return result;
    });
  }

  async listFriends(userId: UUID): Promise<FriendConnection[]> {
    const rows = await this.sql`SELECT f.id request_id, f.status, CASE WHEN f.requester_id=${userId} THEN f.addressee_id ELSE f.requester_id END user_id, CASE WHEN f.requester_id=${userId} THEN 'outgoing' ELSE 'incoming' END direction, p.display_name, p.username FROM friend_requests f JOIN user_profiles p ON p.id=CASE WHEN f.requester_id=${userId} THEN f.addressee_id ELSE f.requester_id END WHERE f.requester_id=${userId} OR f.addressee_id=${userId} ORDER BY f.status, p.display_name`;
    return rows.map((row) => mapFriend(row, row.status === "accepted" ? "friend" : row.direction));
  }

  async requestFriend(userId: UUID, username: string): Promise<FriendConnection> {
    const handle = validUsername(username);
    const [me] = await this.sql`SELECT username FROM user_profiles WHERE id=${userId}`;
    if (!me?.username) throw new ApiError(409, "add your name and username before inviting friends", "profile_incomplete");
    const targets = await this.sql`SELECT id, display_name, username FROM user_profiles WHERE lower(username)=lower(${handle})`;
    if (!targets.length) throw new ApiError(404, "username not found", "not_found");
    const target = targets[0]!;
    if (target.id === userId) throw new ApiError(400, "you cannot invite yourself", "invalid_input");
    try {
      const [row] = await this.sql`INSERT INTO friend_requests (requester_id, addressee_id) VALUES (${userId}, ${target.id}) RETURNING id, status`;
      return { requestId: row!.id, userId: target.id, displayName: target.display_name, username: target.username, status: "pending", direction: "outgoing" };
    } catch (error) { if (isUniqueError(error)) throw new ApiError(409, "a friendship or request already exists", "friend_exists"); throw error; }
  }

  async acceptFriend(userId: UUID, requestId: UUID): Promise<FriendConnection> {
    return this.sql.begin(async (tx) => {
      const rows = await tx`UPDATE friend_requests SET status='accepted', responded_at=now() WHERE id=${requestId} AND addressee_id=${userId} AND status='pending' RETURNING *`;
      if (!rows.length) throw new ApiError(404, "pending friend request not found", "not_found");
      const request = rows[0]!, friendId = request.requester_id;
      const profiles = await tx`SELECT id, display_name, username FROM user_profiles WHERE id IN (${userId}, ${friendId})`;
      const me = profiles.find((row) => row.id === userId)!, friend = profiles.find((row) => row.id === friendId)!;
      await tx`INSERT INTO people (owner_id, display_name, linked_user_id) VALUES (${userId}, ${friend.display_name}, ${friendId}) ON CONFLICT (owner_id, linked_user_id) WHERE linked_user_id IS NOT NULL DO UPDATE SET display_name=EXCLUDED.display_name, updated_at=now()`;
      await tx`INSERT INTO people (owner_id, display_name, linked_user_id) VALUES (${friendId}, ${me.display_name}, ${userId}) ON CONFLICT (owner_id, linked_user_id) WHERE linked_user_id IS NOT NULL DO UPDATE SET display_name=EXCLUDED.display_name, updated_at=now()`;
      return { requestId, userId: friendId, displayName: friend.display_name, username: friend.username, status: "accepted", direction: "friend" };
    });
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
    const rows = await this.sql`SELECT avatar_content_type, avatar_data, avatar_etag FROM user_profiles p WHERE p.id=${userId} AND p.avatar_data IS NOT NULL AND (p.id=${requesterId} OR p.username IS NOT NULL OR EXISTS (SELECT 1 FROM people WHERE owner_id=${requesterId} AND linked_user_id=p.id))`;
    if (!rows.length) return null; const row = rows[0]!; return { contentType: row.avatar_content_type, bytes: toBytes(row.avatar_data), etag: row.avatar_etag };
  }

  async createPerson(ownerId: UUID, displayName: string, linkedUserId?: UUID): Promise<Person> {
    try {
      const linked = linkedUserId ?? null;
      const [row] = await this.sql`INSERT INTO people (owner_id, display_name, linked_user_id) VALUES (${ownerId}, ${validName(displayName, "displayName")}, ${linked}) RETURNING *`;
      return mapPerson(row!);
    } catch (error) { if (isForeignKeyError(error)) throw new ApiError(404, "profile or linked profile not found", "not_found"); throw error; }
  }
  async listPeople(ownerId: UUID): Promise<Person[]> { return (await this.sql`SELECT * FROM people WHERE owner_id=${ownerId} ORDER BY display_name, id`).map(mapPerson); }

  async createSavedFilter(ownerId: UUID, name: string, personIds: UUID[]): Promise<SavedFilter> {
    if (!personIds.length || new Set(personIds).size !== personIds.length || personIds.length > 100) throw new ApiError(400, "personIds must contain 1–100 unique people", "invalid_input");
    return this.sql.begin(async (tx) => {
      const found = await tx`SELECT id FROM people WHERE owner_id=${ownerId} AND id IN ${tx(personIds)}`;
      if (found.length !== personIds.length) throw new ApiError(422, "every filter person must belong to this ledger", "invalid_person");
      const [row] = await tx`INSERT INTO saved_filters (owner_id, name) VALUES (${ownerId}, ${validName(name, "filter name")}) RETURNING *`;
      for (const personId of personIds) await tx`INSERT INTO saved_filter_people (owner_id, filter_id, person_id) VALUES (${ownerId}, ${row!.id}, ${personId})`;
      return { id: row!.id, name: row!.name, personIds: [...personIds], createdAt: toIso(row!.created_at) };
    });
  }
  async listSavedFilters(ownerId: UUID): Promise<SavedFilter[]> {
    const [filters, members] = await Promise.all([this.sql`SELECT * FROM saved_filters WHERE owner_id=${ownerId} ORDER BY name, id`, this.sql`SELECT filter_id, person_id FROM saved_filter_people WHERE owner_id=${ownerId} ORDER BY filter_id, person_id`]);
    return filters.map((row) => ({ id: row.id, name: row.name, personIds: members.filter((m) => m.filter_id === row.id).map((m) => m.person_id), createdAt: toIso(row.created_at) }));
  }

  async createEvidence(ownerId: UUID, kind: EvidenceKind, contentType: string, bytes: Uint8Array): Promise<EvidenceAsset> {
    const etag = imageEtag(bytes);
    const [row] = await this.sql`INSERT INTO evidence_assets (owner_id, uploaded_by, kind, content_type, image_data, image_etag) VALUES (${ownerId}, ${ownerId}, ${kind}, ${contentType}, ${bytes}, ${etag}) RETURNING *`;
    return { id: row!.id, kind: row!.kind, contentType: row!.content_type, etag: row!.image_etag, createdAt: toIso(row!.created_at) };
  }
  async getEvidence(ownerId: UUID, evidenceId: UUID): Promise<StoredImage | null> {
    const rows = await this.sql`SELECT content_type, image_data, image_etag FROM evidence_assets WHERE id=${evidenceId} AND owner_id=${ownerId}`;
    if (!rows.length) return null; return { contentType: rows[0]!.content_type, bytes: toBytes(rows[0]!.image_data), etag: rows[0]!.image_etag };
  }

  async createExpense(ownerId: UUID, input: CreateExpenseInput): Promise<Expense> {
    validateExpense(input); const requestFingerprint = fingerprint(input);
    return this.sql.begin(async (tx) => {
      await tx`SELECT pg_advisory_xact_lock(hashtextextended(${`expense:${ownerId}:${input.clientRequestId}`}, 0))`;
      const prior = await tx`SELECT * FROM expenses WHERE owner_id=${ownerId} AND client_request_id=${input.clientRequestId}`;
      if (prior.length) { if (prior[0]!.request_fingerprint !== requestFingerprint) throw new ApiError(409, "clientRequestId was already used with different data", "idempotency_conflict"); return this.loadExpense(tx, prior[0]!); }
      const ledgers = await tx`SELECT currency FROM ledgers WHERE owner_id=${ownerId} FOR UPDATE`;
      if (!ledgers.length) throw new ApiError(404, "profile not found", "not_found");
      if (ledgers[0]!.currency !== input.currency) throw new ApiError(422, "expense currency must match the ledger currency", "currency_mismatch");
      const personIds = [...new Set([input.payerPersonId, ...input.allocations.map((a) => a.personId)])];
      if ((await tx`SELECT id FROM people WHERE owner_id=${ownerId} AND id IN ${tx(personIds)}`).length !== personIds.length) throw new ApiError(422, "payer and allocations must belong to this ledger", "invalid_person");
      const evidenceIds = input.evidenceIds ?? [];
      if (evidenceIds.length && (await tx`SELECT id FROM evidence_assets WHERE owner_id=${ownerId} AND id IN ${tx(evidenceIds)}`).length !== evidenceIds.length) throw new ApiError(400, "evidence does not belong to this ledger", "invalid_evidence");
      const [row] = await tx`INSERT INTO expenses (owner_id, creator_id, payer_person_id, client_request_id, request_fingerprint, description, currency, total_cents, transaction_date) VALUES (${ownerId}, ${ownerId}, ${input.payerPersonId}, ${input.clientRequestId}, ${requestFingerprint}, ${input.description.trim()}, ${input.currency}, ${input.totalCents}, ${input.transactionDate}) RETURNING *`;
      for (const [position, item] of (input.items ?? []).entries()) await tx`INSERT INTO expense_items (owner_id, expense_id, position, name, amount_cents, offset_cents) VALUES (${ownerId}, ${row!.id}, ${position}, ${item.name.trim()}, ${item.amountCents}, ${item.offsetCents ?? 0})`;
      for (const allocation of input.allocations) await tx`INSERT INTO expense_allocations (owner_id, expense_id, person_id, amount_cents) VALUES (${ownerId}, ${row!.id}, ${allocation.personId}, ${allocation.amountCents})`;
      for (const [position, evidenceId] of evidenceIds.entries()) await tx`INSERT INTO expense_evidence (owner_id, expense_id, evidence_id, position) VALUES (${ownerId}, ${row!.id}, ${evidenceId}, ${position})`;
      const [version] = await tx`UPDATE ledgers SET version=version+1, updated_at=now() WHERE owner_id=${ownerId} RETURNING version`;
      await tx`INSERT INTO audit_events (owner_id, actor_id, ledger_version, event_type, entity_id) VALUES (${ownerId}, ${ownerId}, ${version!.version}, 'expense.created', ${row!.id})`;
      return mapExpense(row!, input.items ?? [], input.allocations, evidenceIds);
    });
  }

  async createPayment(ownerId: UUID, input: CreatePaymentInput): Promise<Payment> {
    validatePayment(input); const requestFingerprint = fingerprint(input);
    return this.sql.begin(async (tx) => {
      await tx`SELECT pg_advisory_xact_lock(hashtextextended(${`payment:${ownerId}:${input.clientRequestId}`}, 0))`;
      const prior = await tx`SELECT * FROM repayments WHERE owner_id=${ownerId} AND client_request_id=${input.clientRequestId}`;
      if (prior.length) { if (prior[0]!.request_fingerprint !== requestFingerprint) throw new ApiError(409, "clientRequestId was already used with different data", "idempotency_conflict"); return mapPayment(prior[0]!); }
      const ids = [input.fromPersonId, input.toPersonId];
      if ((await tx`SELECT id FROM people WHERE owner_id=${ownerId} AND id IN ${tx(ids)}`).length !== 2) throw new ApiError(422, "payment people must belong to this ledger", "invalid_person");
      const [row] = await tx`INSERT INTO repayments (owner_id, recorder_id, from_person_id, to_person_id, client_request_id, request_fingerprint, amount_cents, transaction_date) VALUES (${ownerId}, ${ownerId}, ${input.fromPersonId}, ${input.toPersonId}, ${input.clientRequestId}, ${requestFingerprint}, ${input.amountCents}, ${input.transactionDate}) RETURNING *`;
      const [version] = await tx`UPDATE ledgers SET version=version+1, updated_at=now() WHERE owner_id=${ownerId} RETURNING version`;
      await tx`INSERT INTO audit_events (owner_id, actor_id, ledger_version, event_type, entity_id) VALUES (${ownerId}, ${ownerId}, ${version!.version}, 'repayment.created', ${row!.id})`;
      return mapPayment(row!);
    });
  }

  async getSnapshot(ownerId: UUID, filterId?: UUID): Promise<LedgerSnapshot> {
    const [ledgers, people, savedFilters, expenseRows, itemRows, allocationRows, evidenceRows, paymentRows] = await Promise.all([
      this.sql`SELECT * FROM ledgers WHERE owner_id=${ownerId}`, this.listPeople(ownerId), this.listSavedFilters(ownerId),
      this.sql`SELECT * FROM expenses WHERE owner_id=${ownerId} AND status='active' ORDER BY transaction_date DESC, created_at DESC, id`,
      this.sql`SELECT * FROM expense_items WHERE owner_id=${ownerId} ORDER BY expense_id, position`, this.sql`SELECT * FROM expense_allocations WHERE owner_id=${ownerId} ORDER BY expense_id, person_id`,
      this.sql`SELECT * FROM expense_evidence WHERE owner_id=${ownerId} ORDER BY expense_id, position`, this.sql`SELECT * FROM repayments WHERE owner_id=${ownerId} AND status='active' ORDER BY transaction_date DESC, created_at DESC, id`]);
    if (!ledgers.length) throw new ApiError(404, "profile not found", "not_found");
    let expenses = expenseRows.map((row) => mapExpense(row, itemRows.filter((i) => i.expense_id === row.id).map(mapItem), allocationRows.filter((a) => a.expense_id === row.id).map(mapAllocation), evidenceRows.filter((e) => e.expense_id === row.id).map((e) => e.evidence_id)));
    let payments = paymentRows.map(mapPayment);
    const balances = calculateBalances(people.map((person) => person.id), expenses, payments);
    if (filterId) { const filter = savedFilters.find((f) => f.id === filterId); if (!filter) throw new ApiError(404, "saved filter not found", "not_found"); const selected = new Set(filter.personIds); expenses = expenses.filter((e) => selected.has(e.payerPersonId) || e.allocations.some((a) => selected.has(a.personId))); payments = payments.filter((p) => selected.has(p.fromPersonId) || selected.has(p.toPersonId)); }
    const result: LedgerSnapshot = { version: Number(ledgers[0]!.version), currency: ledgers[0]!.currency, people, savedFilters, expenses, payments, balances };
    if (filterId) result.appliedFilterId = filterId; return result;
  }

  private async loadExpense(sql: any, row: any): Promise<Expense> {
    const [items, allocations, evidence] = await Promise.all([sql`SELECT * FROM expense_items WHERE expense_id=${row.id} ORDER BY position`, sql`SELECT * FROM expense_allocations WHERE expense_id=${row.id} ORDER BY person_id`, sql`SELECT evidence_id FROM expense_evidence WHERE expense_id=${row.id} ORDER BY position`]);
    return mapExpense(row, items.map(mapItem), allocations.map(mapAllocation), evidence.map((e: any) => e.evidence_id));
  }
}

function mapProfile(row: any): Profile { return { id: row.id, firstName: row.first_name, lastName: row.last_name, username: row.username, displayName: row.display_name }; }
function mapPerson(row: any): Person { const person: Person = { id: row.id, displayName: row.display_name, createdAt: toIso(row.created_at) }; if (row.linked_user_id) person.linkedUserId = row.linked_user_id; return person; }
function mapItem(row: any): ExpenseItemInput { return { name: row.name, amountCents: Number(row.amount_cents), offsetCents: Number(row.offset_cents) }; }
function mapAllocation(row: any): AllocationInput { return { personId: row.person_id, amountCents: Number(row.amount_cents) }; }
function mapExpense(row: any, items: ExpenseItemInput[], allocations: AllocationInput[], evidenceIds: UUID[]): Expense { return { id: row.id, ownerId: row.owner_id, creatorId: row.creator_id, clientRequestId: row.client_request_id, description: row.description, transactionDate: String(row.transaction_date), payerPersonId: row.payer_person_id, currency: row.currency, totalCents: Number(row.total_cents), items, allocations, evidenceIds, createdAt: toIso(row.created_at) }; }
function mapPayment(row: any): Payment { return { id: row.id, ownerId: row.owner_id, recorderId: row.recorder_id, clientRequestId: row.client_request_id, fromPersonId: row.from_person_id, toPersonId: row.to_person_id, amountCents: Number(row.amount_cents), transactionDate: String(row.transaction_date), createdAt: toIso(row.created_at) }; }
function mapFriend(row: any, direction: FriendConnection["direction"]): FriendConnection { return { requestId: row.request_id, userId: row.user_id, displayName: row.display_name, username: row.username, status: row.status, direction }; }
function toBytes(value: unknown): Uint8Array { if (value instanceof Uint8Array) return value; throw new Error("PostgreSQL returned an unexpected bytea value"); }
function toIso(value: unknown): string { return value instanceof Date ? value.toISOString() : String(value); }
function isForeignKeyError(error: unknown): boolean { return typeof error === "object" && error !== null && "code" in error && (error as { code?: string }).code === "23503"; }
function isUniqueError(error: unknown): boolean { return typeof error === "object" && error !== null && "code" in error && (error as { code?: string }).code === "23505"; }
function validName(value: string, field: string): string { const trimmed = value.trim(); if (!trimmed || trimmed.length > 100) throw new ApiError(400, `${field} must contain 1–100 characters`, "invalid_input"); return trimmed; }
function validUsername(value: string): string { const username = value.trim().toLowerCase(); if (!/^[a-z0-9_]{3,24}$/.test(username)) throw new ApiError(400, "username must be 3–24 lowercase letters, numbers, or underscores", "invalid_input"); return username; }
