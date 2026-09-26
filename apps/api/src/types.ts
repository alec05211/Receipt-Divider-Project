export type UUID = string;

export interface Profile {
  id: UUID;
  displayName: string;
}

export interface Group {
  id: UUID;
  name: string;
  currency: string;
  version: number;
}

export interface ExpenseItemInput {
  name: string;
  amountCents: number;
  offsetCents?: number;
}

export interface AllocationInput {
  userId: UUID;
  amountCents: number;
}

export interface CreateExpenseInput {
  clientRequestId: UUID;
  description: string;
  transactionDate: string;
  payerId: UUID;
  currency: string;
  receiptId?: UUID;
  items: ExpenseItemInput[];
  allocations: AllocationInput[];
}

export interface Expense extends CreateExpenseInput {
  id: UUID;
  groupId: UUID;
  creatorId: UUID;
  totalCents: number;
  createdAt: string;
}

export interface CreatePaymentInput {
  clientRequestId: UUID;
  fromUserId: UUID;
  toUserId: UUID;
  amountCents: number;
  transactionDate: string;
}

export interface Payment extends CreatePaymentInput {
  id: UUID;
  groupId: UUID;
  recorderId: UUID;
  createdAt: string;
}

export interface GroupSnapshot {
  group: Group;
  members: Profile[];
  expenses: Expense[];
  payments: Payment[];
  balances: Record<UUID, number>;
}

export interface StoredImage {
  contentType: string;
  bytes: Uint8Array;
  etag: string;
}

export interface LedgerRepository {
  upsertProfile(userId: UUID, displayName: string): Promise<Profile>;
  putAvatar(userId: UUID, contentType: string, bytes: Uint8Array): Promise<string>;
  getAvatar(requesterId: UUID, userId: UUID): Promise<StoredImage | null>;
  createGroup(actorId: UUID, name: string, currency: string): Promise<Group>;
  addMember(actorId: UUID, groupId: UUID, userId: UUID): Promise<void>;
  createReceipt(actorId: UUID, groupId: UUID, contentType: string, bytes: Uint8Array): Promise<UUID>;
  getReceipt(actorId: UUID, receiptId: UUID): Promise<StoredImage | null>;
  createExpense(actorId: UUID, groupId: UUID, input: CreateExpenseInput): Promise<Expense>;
  createPayment(actorId: UUID, groupId: UUID, input: CreatePaymentInput): Promise<Payment>;
  getSnapshot(actorId: UUID, groupId: UUID): Promise<GroupSnapshot>;
  close?(): Promise<void>;
}

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    message: string,
    public readonly code = "request_failed",
  ) {
    super(message);
  }
}
