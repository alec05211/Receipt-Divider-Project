export type UUID = string;

/** A profile exists as soon as the user signs in; the name fields stay null until they set them. */
export interface Profile { id: UUID; firstName: string | null; lastName: string | null; username: string | null; displayName: string | null; isDeveloper: boolean; }
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

/** A manually chosen label for what an expense was for; expenses without one have none. */
export const expenseCategories = ["groceries", "restaurant", "movie", "concert"] as const;
export type ExpenseCategory = typeof expenseCategories[number];

/** What a receipt row is, as the device's model labels it. */
export const receiptRowKinds = ["item", "detail", "itemDiscount", "subtotal", "orderDiscount", "tax", "tip", "surcharge", "total", "cashTotal", "other"] as const;
export type ReceiptRowKind = typeof receiptRowKinds[number];

/**
 * A receipt read from its photo: its printed rows top to bottom, each with a label, plus what only reading it can tell.
 * Amounts stay in each row's text; the app reads them and works out the expense as it does for an on-device reading.
 * Empty strings mean not found.
 */
export interface ReceiptReading {
  merchant: string;
  category: string;
  purchaseDate: string;
  rows: { text: string; kind: ReceiptRowKind; taxed: boolean }[];
  expenseName: string;
}

export interface ReceiptVisionParser {
  /** `note` is a problem with a first reading, for a re-read. */
  parseReceipt(contentType: string, bytes: Uint8Array, note?: string): Promise<ReceiptReading>;
}

export const expenseItemKinds = ["item", "tip"] as const;
/** A tip row is split evenly among its owners rather than priced like an item. */
export type ExpenseItemKind = typeof expenseItemKinds[number];

/**
 * `amountCents` is the price printed on the receipt. `localOffsetCents` is what the receipt ties to that item (its own
 * discount), and `globalOffsetCents` is its share of receipt-wide adjustments, so the item costs the sum of all three.
 * `ownerIds` are the people who had the item; each must be the payer or have an allocation on the expense. An item with
 * no owners belongs to the payer. Owners record who had what; the allocations alone set what each person owes.
 */
export interface ExpenseItemInput {
  name: string;
  amountCents: number;
  localOffsetCents?: number;
  globalOffsetCents?: number;
  /** What older clients send for `globalOffsetCents`. */
  offsetCents?: number;
  kind?: ExpenseItemKind;
  /** Whether receipt tax applies to the item; defaults to true. */
  taxed?: boolean;
  ownerIds?: UUID[];
}
export interface ExpenseItem {
  name: string;
  amountCents: number;
  localOffsetCents: number;
  globalOffsetCents: number;
  kind: ExpenseItemKind;
  taxed: boolean;
  ownerIds: UUID[];
}

export const adjustmentKinds = ["discount", "tax", "tip", "surcharge"] as const;
export type AdjustmentKind = typeof adjustmentKinds[number];
/**
 * A receipt-wide adjustment, listed in the order the receipt applies it. `rate` is a fraction of the running cost of
 * the items it applies to (0.06 for 6% tax) and is null for a tip. `amountCents` is what it came to in this expense.
 */
export interface ExpenseAdjustment { kind: AdjustmentKind; amountCents: number; rate: number | null; }
/** The fields of an existing expense that can be edited; omitted fields are left as they are. */
export interface ExpenseChanges { description?: string; transactionDate?: string; }
export interface AllocationInput { userId: UUID; amountCents: number; }

/** The payer and everyone allocated a share must be the creator or one of the creator's friends. */
export interface CreateExpenseInput {
  clientRequestId: UUID;
  description: string;
  /** Optional; omitted or null means uncategorized. */
  category?: ExpenseCategory | null;
  transactionDate: string;
  payerId: UUID;
  currency: string;
  totalCents: number;
  evidenceIds?: UUID[];
  /** Omitted or empty: the expense is saved as one item for the whole total, owned by everyone allocated. */
  items?: ExpenseItemInput[];
  /** Omitted or empty: the expense has no receipt-wide adjustments. */
  adjustments?: ExpenseAdjustment[];
  allocations: AllocationInput[];
}

export interface Expense extends Omit<CreateExpenseInput, "items" | "adjustments" | "evidenceIds" | "category"> {
  id: UUID;
  category: ExpenseCategory | null;
  creatorId: UUID;
  items: ExpenseItem[];
  adjustments: ExpenseAdjustment[];
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

export type SliderUnit = "dollars" | "percent";
/** Account-wide preferences. Currency is fixed for now; the slider unit is how contributions are entered. */
export interface UserSettings { currency: string; sliderUnit: SliderUnit; }

export interface StoredImage { contentType: string; bytes: Uint8Array; etag: string; }

export interface LedgerRepository {
  checkHealth(): Promise<void>;
  /** Creates the profile and its settings if missing. */
  ensureProfile(userId: UUID): Promise<Profile>;
  getProfile(userId: UUID): Promise<Profile>;
  getSettings(userId: UUID): Promise<UserSettings>;
  updateSettings(userId: UUID, changes: Partial<Pick<UserSettings, "sliderUnit">>): Promise<UserSettings>;
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
  /**
   * Evidence is visible to its uploader and to everyone on an expense it's attached to. One receipt may be attached
   * to several expenses split from it, so expenses sharing an evidence ID came from the same receipt.
   */
  getEvidence(requesterId: UUID, evidenceId: UUID): Promise<StoredImage | null>;
  /**
   * Stores the text the uploader's device recognized in their evidence image, with optional diagnostics describing how
   * it was read; returns false if it isn't theirs.
   */
  putEvidenceText(uploaderId: UUID, evidenceId: UUID, text: string, diagnostics?: object | null): Promise<boolean>;
  createExpense(creatorId: UUID, input: CreateExpenseInput): Promise<Expense>;
  /**
   * Edits an active expense's name and/or transaction date. Only its payer may edit it (403 for anyone else on it); to
   * anyone not on it, it doesn't exist (404). Each changed field is recorded as an attributable revision holding the
   * old and new values. Amounts and allocations are untouched, so balances don't change.
   */
  updateExpense(userId: UUID, expenseId: UUID, changes: ExpenseChanges): Promise<Expense>;
  createPayment(recorderId: UUID, input: CreatePaymentInput): Promise<Payment>;
  getSnapshot(userId: UUID, filterId?: UUID): Promise<LedgerSnapshot>;
  /**
   * Developer-only (403 otherwise): deletes every account's expenses, their items, allocations, and evidence, every
   * payment, and all revision history. Profiles, settings, friendships, and saved filters are kept.
   */
  resetLedgerData(userId: UUID): Promise<void>;
  close?(): Promise<void>;
}

export class ApiError extends Error {
  constructor(public readonly status: number, message: string, public readonly code = "request_failed") { super(message); }
}
