import postgres from "postgres";
import { calculateBalances, fingerprint, imageEtag, validateExpense, validatePayment } from "./domain.js";
import type {
  AllocationInput,
  CreateExpenseInput,
  CreatePaymentInput,
  Expense,
  ExpenseItemInput,
  Group,
  GroupSnapshot,
  LedgerRepository,
  Payment,
  Profile,
  StoredImage,
  UUID,
} from "./types.js";
import { ApiError } from "./types.js";

export class PostgresRepository implements LedgerRepository {
  private readonly sql: ReturnType<typeof postgres>;

  constructor(databaseUrl: string) {
    this.sql = postgres(databaseUrl, { max: 5, idle_timeout: 20, connect_timeout: 10 });
  }

  async close(): Promise<void> {
    await this.sql.end();
  }

  async upsertProfile(userId: UUID, displayName: string): Promise<Profile> {
    const trimmed = displayName.trim();
    if (!trimmed || trimmed.length > 100) throw new ApiError(400, "displayName must contain 1–100 characters", "invalid_input");
    const [row] = await this.sql`
      INSERT INTO user_profiles (id, display_name) VALUES (${userId}, ${trimmed})
      ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name, updated_at = now()
      RETURNING id, display_name`;
    return { id: row!.id, displayName: row!.display_name };
  }

  async putAvatar(userId: UUID, contentType: string, bytes: Uint8Array): Promise<string> {
    const etag = imageEtag(bytes);
    const rows = await this.sql`
      UPDATE user_profiles SET avatar_content_type = ${contentType}, avatar_data = ${bytes}, avatar_etag = ${etag},
        avatar_updated_at = now(), updated_at = now() WHERE id = ${userId} RETURNING id`;
    if (!rows.length) throw new ApiError(404, "profile not found", "not_found");
    return etag;
  }

  async getAvatar(requesterId: UUID, userId: UUID): Promise<StoredImage | null> {
    const rows = await this.sql`
      SELECT p.avatar_content_type, p.avatar_data, p.avatar_etag
      FROM user_profiles p
      WHERE p.id = ${userId} AND p.avatar_data IS NOT NULL AND (
        p.id = ${requesterId} OR EXISTS (
          SELECT 1 FROM memberships mine
          JOIN memberships theirs ON theirs.group_id = mine.group_id
          WHERE mine.user_id = ${requesterId} AND mine.state = 'active'
            AND theirs.user_id = p.id AND theirs.state = 'active'
        )
      )`;
    if (!rows.length) return null;
    const row = rows[0]!;
    return { contentType: row.avatar_content_type, bytes: toBytes(row.avatar_data), etag: row.avatar_etag };
  }

  async createGroup(actorId: UUID, name: string, currency: string): Promise<Group> {
    const trimmed = name.trim();
    if (!trimmed || trimmed.length > 100) throw new ApiError(400, "group name must contain 1–100 characters", "invalid_input");
    return this.sql.begin(async (tx) => {
      const [row] = await tx`
        INSERT INTO groups (name, currency, created_by) VALUES (${trimmed}, ${currency}, ${actorId})
        RETURNING id, name, currency, version`;
      await tx`INSERT INTO memberships (group_id, user_id, role) VALUES (${row!.id}, ${actorId}, 'owner')`;
      return mapGroup(row!);
    });
  }

  async addMember(actorId: UUID, groupId: UUID, userId: UUID): Promise<void> {
    const owners = await this.sql`SELECT 1 FROM memberships WHERE group_id = ${groupId} AND user_id = ${actorId} AND role = 'owner' AND state = 'active'`;
    if (!owners.length) throw new ApiError(403, "only a group owner can add members", "forbidden");
    try {
      await this.sql`
        INSERT INTO memberships (group_id, user_id, role, state) VALUES (${groupId}, ${userId}, 'member', 'active')
        ON CONFLICT (group_id, user_id) DO UPDATE SET state = 'active'`;
    } catch (error) {
      if (isForeignKeyError(error)) throw new ApiError(404, "profile or group not found", "not_found");
      throw error;
    }
  }

  async createReceipt(actorId: UUID, groupId: UUID, contentType: string, bytes: Uint8Array): Promise<UUID> {
    const etag = imageEtag(bytes);
    try {
      const [row] = await this.sql`
        INSERT INTO receipts (group_id, uploaded_by, content_type, image_data, image_etag)
        SELECT ${groupId}, ${actorId}, ${contentType}, ${bytes}, ${etag}
        FROM memberships WHERE group_id = ${groupId} AND user_id = ${actorId} AND state = 'active'
        RETURNING id`;
      if (!row) throw new ApiError(403, "user is not an active member of this group", "forbidden");
      return row!.id;
    } catch (error) {
      if (isForeignKeyError(error)) throw new ApiError(403, "user is not an active member of this group", "forbidden");
      throw error;
    }
  }

  async getReceipt(actorId: UUID, receiptId: UUID): Promise<StoredImage | null> {
    const rows = await this.sql`
      SELECT r.content_type, r.image_data, r.image_etag
      FROM receipts r JOIN memberships m ON m.group_id = r.group_id
      WHERE r.id = ${receiptId} AND m.user_id = ${actorId} AND m.state = 'active'`;
    if (!rows.length) return null;
    const row = rows[0]!;
    return { contentType: row.content_type, bytes: toBytes(row.image_data), etag: row.image_etag };
  }

  async createExpense(actorId: UUID, groupId: UUID, input: CreateExpenseInput): Promise<Expense> {
    const totalCents = validateExpense(input);
    const requestFingerprint = fingerprint(input);
    return this.sql.begin(async (tx) => {
      await tx`SELECT pg_advisory_xact_lock(hashtextextended(${`expense:${actorId}:${input.clientRequestId}`}, 0))`;
      const prior = await tx`SELECT * FROM expenses WHERE creator_id = ${actorId} AND client_request_id = ${input.clientRequestId}`;
      if (prior.length) {
        if (prior[0]!.group_id !== groupId) throw new ApiError(409, "clientRequestId was already used in another group", "idempotency_conflict");
        if (prior[0]!.request_fingerprint !== requestFingerprint) throw new ApiError(409, "clientRequestId was already used with different data", "idempotency_conflict");
        return this.loadExpense(tx, prior[0]!);
      }

      const groupRows = await tx`
        SELECT g.currency FROM groups g JOIN memberships m ON m.group_id = g.id
        WHERE g.id = ${groupId} AND m.user_id = ${actorId} AND m.state = 'active' FOR UPDATE OF g`;
      if (!groupRows.length) throw new ApiError(403, "user is not an active member of this group", "forbidden");
      if (groupRows[0]!.currency !== input.currency) throw new ApiError(422, "expense currency must match the group currency", "currency_mismatch");

      const memberRows = await tx`SELECT user_id FROM memberships WHERE group_id = ${groupId} AND state = 'active'`;
      const members = new Set(memberRows.map((row) => row.user_id as string));
      if (!members.has(input.payerId) || input.allocations.some((item) => !members.has(item.userId))) {
        throw new ApiError(422, "payer and allocations must reference active group members", "invalid_member");
      }
      if (input.receiptId) {
        const receipts = await tx`SELECT 1 FROM receipts WHERE id = ${input.receiptId} AND group_id = ${groupId}`;
        if (!receipts.length) throw new ApiError(400, "receipt does not belong to this group", "invalid_receipt");
      }

      const receiptId = input.receiptId ?? null;
      const [row] = await tx`
        INSERT INTO expenses (group_id, creator_id, payer_id, receipt_id, client_request_id, request_fingerprint,
          description, currency, total_cents, transaction_date)
        VALUES (${groupId}, ${actorId}, ${input.payerId}, ${receiptId}, ${input.clientRequestId}, ${requestFingerprint},
          ${input.description.trim()}, ${input.currency}, ${totalCents}, ${input.transactionDate}) RETURNING *`;
      for (const [position, item] of input.items.entries()) {
        await tx`INSERT INTO expense_items (expense_id, position, name, amount_cents, offset_cents)
          VALUES (${row!.id}, ${position}, ${item.name.trim()}, ${item.amountCents}, ${item.offsetCents ?? 0})`;
      }
      for (const allocation of input.allocations) {
        await tx`INSERT INTO expense_allocations (expense_id, group_id, user_id, amount_cents)
          VALUES (${row!.id}, ${groupId}, ${allocation.userId}, ${allocation.amountCents})`;
      }
      const [version] = await tx`UPDATE groups SET version = version + 1 WHERE id = ${groupId} RETURNING version`;
      await tx`INSERT INTO audit_events (group_id, actor_id, group_version, event_type, entity_id)
        VALUES (${groupId}, ${actorId}, ${version!.version}, 'expense.created', ${row!.id})`;
      return mapExpense(row!, input.items, input.allocations);
    });
  }

  async createPayment(actorId: UUID, groupId: UUID, input: CreatePaymentInput): Promise<Payment> {
    validatePayment(input);
    const requestFingerprint = fingerprint(input);
    return this.sql.begin(async (tx) => {
      await tx`SELECT pg_advisory_xact_lock(hashtextextended(${`payment:${actorId}:${input.clientRequestId}`}, 0))`;
      const prior = await tx`SELECT * FROM repayments WHERE recorder_id = ${actorId} AND client_request_id = ${input.clientRequestId}`;
      if (prior.length) {
        if (prior[0]!.group_id !== groupId) throw new ApiError(409, "clientRequestId was already used in another group", "idempotency_conflict");
        if (prior[0]!.request_fingerprint !== requestFingerprint) throw new ApiError(409, "clientRequestId was already used with different data", "idempotency_conflict");
        return mapPayment(prior[0]!);
      }
      const groupRows = await tx`
        SELECT g.id FROM groups g JOIN memberships m ON m.group_id = g.id
        WHERE g.id = ${groupId} AND m.user_id = ${actorId} AND m.state = 'active' FOR UPDATE OF g`;
      if (!groupRows.length) throw new ApiError(403, "user is not an active member of this group", "forbidden");
      const people = await tx`SELECT user_id FROM memberships WHERE group_id = ${groupId} AND state = 'active' AND user_id IN (${input.fromUserId}, ${input.toUserId})`;
      if (people.length !== 2) throw new ApiError(422, "payment participants must be active group members", "invalid_member");
      const [row] = await tx`
        INSERT INTO repayments (group_id, recorder_id, from_user_id, to_user_id, client_request_id,
          request_fingerprint, amount_cents, transaction_date)
        VALUES (${groupId}, ${actorId}, ${input.fromUserId}, ${input.toUserId}, ${input.clientRequestId},
          ${requestFingerprint}, ${input.amountCents}, ${input.transactionDate}) RETURNING *`;
      const [version] = await tx`UPDATE groups SET version = version + 1 WHERE id = ${groupId} RETURNING version`;
      await tx`INSERT INTO audit_events (group_id, actor_id, group_version, event_type, entity_id)
        VALUES (${groupId}, ${actorId}, ${version!.version}, 'repayment.created', ${row!.id})`;
      return mapPayment(row!);
    });
  }

  async getSnapshot(actorId: UUID, groupId: UUID): Promise<GroupSnapshot> {
    const [groupRows, memberRows, expenseRows, itemRows, allocationRows, paymentRows] = await Promise.all([
      this.sql`SELECT g.* FROM groups g JOIN memberships m ON m.group_id = g.id WHERE g.id = ${groupId} AND m.user_id = ${actorId} AND m.state = 'active'`,
      this.sql`SELECT p.id, p.display_name FROM memberships m JOIN user_profiles p ON p.id = m.user_id WHERE m.group_id = ${groupId} AND m.state = 'active' ORDER BY p.display_name`,
      this.sql`SELECT * FROM expenses WHERE group_id = ${groupId} AND status = 'active' ORDER BY transaction_date DESC, created_at DESC, id`,
      this.sql`SELECT i.* FROM expense_items i JOIN expenses e ON e.id = i.expense_id WHERE e.group_id = ${groupId} AND e.status = 'active' ORDER BY i.expense_id, i.position`,
      this.sql`SELECT a.* FROM expense_allocations a JOIN expenses e ON e.id = a.expense_id WHERE e.group_id = ${groupId} AND e.status = 'active' ORDER BY a.expense_id, a.user_id`,
      this.sql`SELECT * FROM repayments WHERE group_id = ${groupId} AND status = 'active' ORDER BY transaction_date DESC, created_at DESC, id`,
    ]);
    if (!groupRows.length) throw new ApiError(403, "user is not an active member of this group", "forbidden");
    const members = memberRows.map((row) => ({ id: row.id, displayName: row.display_name }));
    const expenses = expenseRows.map((row) => mapExpense(
      row,
      itemRows.filter((item) => item.expense_id === row.id).map(mapItem),
      allocationRows.filter((allocation) => allocation.expense_id === row.id).map(mapAllocation),
    ));
    const payments = paymentRows.map(mapPayment);
    return {
      group: mapGroup(groupRows[0]!), members, expenses, payments,
      balances: calculateBalances(members.map((member) => member.id), expenses, payments),
    };
  }

  private async loadExpense(sql: any, row: any): Promise<Expense> {
    const [items, allocations] = await Promise.all([
      sql`SELECT * FROM expense_items WHERE expense_id = ${row.id} ORDER BY position`,
      sql`SELECT * FROM expense_allocations WHERE expense_id = ${row.id} ORDER BY user_id`,
    ]);
    return mapExpense(row, items.map(mapItem), allocations.map(mapAllocation));
  }
}

function mapGroup(row: any): Group {
  return { id: row.id, name: row.name, currency: row.currency, version: Number(row.version) };
}

function mapItem(row: any): ExpenseItemInput {
  return { name: row.name, amountCents: Number(row.amount_cents), offsetCents: Number(row.offset_cents) };
}

function mapAllocation(row: any): AllocationInput {
  return { userId: row.user_id, amountCents: Number(row.amount_cents) };
}

function mapExpense(row: any, items: ExpenseItemInput[], allocations: AllocationInput[]): Expense {
  const expense: Expense = {
    id: row.id, groupId: row.group_id, creatorId: row.creator_id, clientRequestId: row.client_request_id,
    description: row.description, transactionDate: String(row.transaction_date), payerId: row.payer_id,
    currency: row.currency, items, allocations, totalCents: Number(row.total_cents), createdAt: toIso(row.created_at),
  };
  if (row.receipt_id) expense.receiptId = row.receipt_id;
  return expense;
}

function mapPayment(row: any): Payment {
  return {
    id: row.id, groupId: row.group_id, recorderId: row.recorder_id, clientRequestId: row.client_request_id,
    fromUserId: row.from_user_id, toUserId: row.to_user_id, amountCents: Number(row.amount_cents),
    transactionDate: String(row.transaction_date), createdAt: toIso(row.created_at),
  };
}

function toBytes(value: unknown): Uint8Array {
  if (value instanceof Uint8Array) return value;
  throw new Error("PostgreSQL returned an unexpected bytea value");
}

function toIso(value: unknown): string {
  return value instanceof Date ? value.toISOString() : String(value);
}

function isForeignKeyError(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && (error as { code?: string }).code === "23503";
}
