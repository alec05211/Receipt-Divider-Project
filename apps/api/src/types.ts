export type UUID = string;

/** A profile exists as soon as the user signs in; the name fields stay null until they set them. */
export interface Profile { id: UUID; firstName: string | null; lastName: string | null; username: string | null; displayName: string | null; }
export interface ProfileIdentity { id: UUID; firstName: string; lastName: string; username: string; displayName: string; }
/** Where the searcher stands with a search result: no request, a request either way, or already friends. */
export type Relationship = "none" | "outgoing" | "incoming" | "friend";
/** `avatarEtag` changes whenever the person uploads a new photo, so clients know when to refetch it; null means no photo. */
export interface UserSearchResult { userId: UUID; displayName: string; username: string; hasAvatar: boolean; avatarEtag: string | null; relationship: Relationship; requestId?: UUID; }
export interface FriendConnection { requestId: UUID; userId: UUID; displayName: string; username: string; avatarEtag: string | null; status: "pending" | "accepted"; direction: "incoming" | "outgoing" | "friend"; }

/** Someone who appears in the caller's ledger: the caller, a friend, or anyone they share a transaction with. */
export interface LedgerPerson { userId: UUID; displayName: string | null; username: string | null; avatarEtag: string | null; }

/** A personal shortcut for filtering transactions to those involving any of these users. */
export interface SavedFilter {
  id: UUID;
  name: string;
  userIds: UUID[];
  createdAt: string;
}

export type EvidenceKind = "receipt" | "restaurant_check" | "ticket_confirmation" | "other";
export interface EvidenceAsset { id: UUID; kind: EvidenceKind; contentType: string; etag: string; createdAt: string; }

export interface ExpenseItemInput { name: string; amountCents: number; offsetCents?: number; }
export interface AllocationInput { userId: UUID; amountCents: number; }

/** The payer and everyone allocated a share must be the creator or one of the creator's friends. */
export interface CreateExpenseInput {
  clientRequestId: UUID;
  description: string;
  transactionDate: string;
  payerId: UUID;
  currency: string;
  totalCents: number;
  evidenceIds?: UUID[];
  items?: ExpenseItemInput[];
  allocations: AllocationInput[];
}

export interface Expense extends Omit<CreateExpenseInput, "items" | "evidenceIds"> {
  id: UUID;
  creatorId: UUID;
  items: ExpenseItemInput[];
  evidenceIds: UUID[];
  createdAt: string;
}

/** One side of the payment must be the person recording it. */
export interface CreatePaymentInput {
  clientRequestId: UUID;
  fromUserId: UUID;
  toUserId: UUID;
  amountCents: number;
  transactionDate: string;
}

export interface Payment extends CreatePaymentInput { id: UUID; recorderId: UUID; createdAt: string; }

/**
 * Everything visible to one user. `balances` is from the caller's side: a positive amount means that person owes
 * the caller, a negative one that the caller owes them. `netBalance` is their sum.
 */
export interface LedgerSnapshot {
  currency: string;
  appliedFilterId?: UUID;
  people: LedgerPerson[];
  savedFilters: SavedFilter[];
  expenses: Expense[];
  payments: Payment[];
  balances: Record<UUID, number>;
  netBalance: number;
}

export interface StoredImage { contentType: string; bytes: Uint8Array; etag: string; }

export interface LedgerRepository {
  checkHealth(): Promise<void>;
  ensureProfile(userId: UUID): Promise<Profile>;
  getProfile(userId: UUID): Promise<Profile>;
  updateIdentity(userId: UUID, firstName: string, lastName: string, username: string): Promise<ProfileIdentity>;
  searchUsers(userId: UUID, query: string): Promise<UserSearchResult[]>;
  listFriends(userId: UUID): Promise<FriendConnection[]>;
  requestFriend(userId: UUID, username: string): Promise<FriendConnection>;
  acceptFriend(userId: UUID, requestId: UUID): Promise<FriendConnection>;
  /** Ends the friendship (or withdraws a pending request) with another user; shared transactions are kept. */
  removeFriend(userId: UUID, friendId: UUID): Promise<void>;
  putAvatar(userId: UUID, contentType: string, bytes: Uint8Array): Promise<string>;
  getAvatar(requesterId: UUID, userId: UUID): Promise<StoredImage | null>;
  createSavedFilter(ownerId: UUID, name: string, userIds: UUID[]): Promise<SavedFilter>;
  listSavedFilters(ownerId: UUID): Promise<SavedFilter[]>;
  createEvidence(ownerId: UUID, kind: EvidenceKind, contentType: string, bytes: Uint8Array): Promise<EvidenceAsset>;
  /** Evidence is visible to its uploader and to everyone on an expense it's attached to. */
  getEvidence(requesterId: UUID, evidenceId: UUID): Promise<StoredImage | null>;
  createExpense(creatorId: UUID, input: CreateExpenseInput): Promise<Expense>;
  createPayment(recorderId: UUID, input: CreatePaymentInput): Promise<Payment>;
  getSnapshot(userId: UUID, filterId?: UUID): Promise<LedgerSnapshot>;
  close?(): Promise<void>;
}

export class ApiError extends Error {
  constructor(public readonly status: number, message: string, public readonly code = "request_failed") { super(message); }
}
