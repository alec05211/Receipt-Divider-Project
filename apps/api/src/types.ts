export type UUID = string;

export interface Profile { id: UUID; displayName: string; }

export interface Person {
  id: UUID;
  displayName: string;
  linkedUserId?: UUID;
  createdAt: string;
}

export interface SavedFilter {
  id: UUID;
  name: string;
  personIds: UUID[];
  createdAt: string;
}

export type EvidenceKind = "receipt" | "restaurant_check" | "ticket_confirmation" | "other";
export interface EvidenceAsset { id: UUID; kind: EvidenceKind; contentType: string; etag: string; createdAt: string; }

export interface ExpenseItemInput { name: string; amountCents: number; offsetCents?: number; }
export interface AllocationInput { personId: UUID; amountCents: number; }

export interface CreateExpenseInput {
  clientRequestId: UUID;
  description: string;
  transactionDate: string;
  payerPersonId: UUID;
  currency: string;
  totalCents: number;
  evidenceIds?: UUID[];
  items?: ExpenseItemInput[];
  allocations: AllocationInput[];
}

export interface Expense extends Omit<CreateExpenseInput, "items" | "evidenceIds"> {
  id: UUID;
  ownerId: UUID;
  creatorId: UUID;
  items: ExpenseItemInput[];
  evidenceIds: UUID[];
  createdAt: string;
}

export interface CreatePaymentInput {
  clientRequestId: UUID;
  fromPersonId: UUID;
  toPersonId: UUID;
  amountCents: number;
  transactionDate: string;
}

export interface Payment extends CreatePaymentInput { id: UUID; ownerId: UUID; recorderId: UUID; createdAt: string; }

export interface LedgerSnapshot {
  version: number;
  currency: string;
  appliedFilterId?: UUID;
  people: Person[];
  savedFilters: SavedFilter[];
  expenses: Expense[];
  payments: Payment[];
  balances: Record<UUID, number>;
}

export interface StoredImage { contentType: string; bytes: Uint8Array; etag: string; }

export interface LedgerRepository {
  checkHealth(): Promise<void>;
  upsertProfile(userId: UUID, displayName: string): Promise<Profile>;
  putAvatar(userId: UUID, contentType: string, bytes: Uint8Array): Promise<string>;
  getAvatar(requesterId: UUID, userId: UUID): Promise<StoredImage | null>;
  createPerson(ownerId: UUID, displayName: string, linkedUserId?: UUID): Promise<Person>;
  listPeople(ownerId: UUID): Promise<Person[]>;
  createSavedFilter(ownerId: UUID, name: string, personIds: UUID[]): Promise<SavedFilter>;
  listSavedFilters(ownerId: UUID): Promise<SavedFilter[]>;
  createEvidence(ownerId: UUID, kind: EvidenceKind, contentType: string, bytes: Uint8Array): Promise<EvidenceAsset>;
  getEvidence(ownerId: UUID, evidenceId: UUID): Promise<StoredImage | null>;
  createExpense(ownerId: UUID, input: CreateExpenseInput): Promise<Expense>;
  createPayment(ownerId: UUID, input: CreatePaymentInput): Promise<Payment>;
  getSnapshot(ownerId: UUID, filterId?: UUID): Promise<LedgerSnapshot>;
  close?(): Promise<void>;
}

export class ApiError extends Error {
  constructor(public readonly status: number, message: string, public readonly code = "request_failed") { super(message); }
}
