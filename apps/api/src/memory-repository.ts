import { randomUUID } from "node:crypto";
import { calculateBalances, fingerprint, imageEtag, validateExpense, validatePayment } from "./domain.ts";
import type { CreateExpenseInput, CreatePaymentInput, EvidenceAsset, EvidenceKind, Expense, LedgerRepository, LedgerSnapshot, Payment, Person, Profile, SavedFilter, StoredImage, UUID } from "./types.ts";
import { ApiError } from "./types.ts";

interface ImageRecord extends StoredImage { ownerId: UUID; kind?: EvidenceKind; createdAt?: string; }
interface Ledger { currency: string; version: number; }

/** Test/local adapter. It deliberately has no persistence and is never selected when DATABASE_URL is set. */
export class MemoryRepository implements LedgerRepository {
  private profiles = new Map<UUID, Profile>();
  private ledgers = new Map<UUID, Ledger>();
  private avatars = new Map<UUID, ImageRecord>();
  private people = new Map<UUID, Person[]>();
  private filters = new Map<UUID, SavedFilter[]>();
  private evidence = new Map<UUID, ImageRecord>();
  private expenses = new Map<UUID, Expense[]>();
  private payments = new Map<UUID, Payment[]>();
  private requests = new Map<string, { fingerprint: string; value: Expense | Payment }>();

  async checkHealth(): Promise<void> {}

  async upsertProfile(userId: UUID, displayName: string): Promise<Profile> {
    const trimmed = validName(displayName, "displayName");
    const profile = { id: userId, displayName: trimmed };
    this.profiles.set(userId, profile);
    if (!this.ledgers.has(userId)) {
      this.ledgers.set(userId, { currency: "USD", version: 0 });
      this.people.set(userId, []); this.filters.set(userId, []); this.expenses.set(userId, []); this.payments.set(userId, []);
    }
    return profile;
  }

  async putAvatar(userId: UUID, contentType: string, bytes: Uint8Array): Promise<string> {
    this.requireOwner(userId);
    const etag = imageEtag(bytes);
    this.avatars.set(userId, { ownerId: userId, contentType, bytes: Uint8Array.from(bytes), etag });
    return etag;
  }

  async getAvatar(requesterId: UUID, userId: UUID): Promise<StoredImage | null> {
    this.requireOwner(requesterId);
    const linked = (this.people.get(requesterId) ?? []).some((person) => person.linkedUserId === userId);
    if (requesterId !== userId && !linked) throw new ApiError(403, "avatar is not visible to this user", "forbidden");
    return this.avatars.get(userId) ?? null;
  }

  async createPerson(ownerId: UUID, displayName: string, linkedUserId?: UUID): Promise<Person> {
    this.requireOwner(ownerId);
    if (linkedUserId && !this.profiles.has(linkedUserId)) throw new ApiError(404, "linked profile not found", "not_found");
    const person: Person = { id: randomUUID(), displayName: validName(displayName, "displayName"), createdAt: new Date().toISOString() };
    if (linkedUserId) person.linkedUserId = linkedUserId;
    this.people.get(ownerId)!.push(person);
    return structuredClone(person);
  }

  async listPeople(ownerId: UUID): Promise<Person[]> { this.requireOwner(ownerId); return structuredClone(this.people.get(ownerId)!); }

  async createSavedFilter(ownerId: UUID, name: string, personIds: UUID[]): Promise<SavedFilter> {
    this.requireOwner(ownerId);
    const unique = new Set(personIds);
    if (!personIds.length || unique.size !== personIds.length || personIds.length > 100) throw new ApiError(400, "personIds must contain 1–100 unique people", "invalid_input");
    personIds.forEach((id) => this.requirePerson(ownerId, id));
    const filter = { id: randomUUID(), name: validName(name, "filter name"), personIds: [...personIds], createdAt: new Date().toISOString() };
    this.filters.get(ownerId)!.push(filter);
    return structuredClone(filter);
  }

  async listSavedFilters(ownerId: UUID): Promise<SavedFilter[]> { this.requireOwner(ownerId); return structuredClone(this.filters.get(ownerId)!); }

  async createEvidence(ownerId: UUID, kind: EvidenceKind, contentType: string, bytes: Uint8Array): Promise<EvidenceAsset> {
    this.requireOwner(ownerId);
    const id = randomUUID(), etag = imageEtag(bytes), createdAt = new Date().toISOString();
    this.evidence.set(id, { ownerId, kind, contentType, bytes: Uint8Array.from(bytes), etag, createdAt });
    return { id, kind, contentType, etag, createdAt };
  }

  async getEvidence(ownerId: UUID, evidenceId: UUID): Promise<StoredImage | null> {
    this.requireOwner(ownerId);
    const image = this.evidence.get(evidenceId);
    return image?.ownerId === ownerId ? image : null;
  }

  async createExpense(ownerId: UUID, input: CreateExpenseInput): Promise<Expense> {
    const ledger = this.requireOwner(ownerId); validateExpense(input);
    if (ledger.currency !== input.currency) throw new ApiError(422, "expense currency must match the ledger currency", "currency_mismatch");
    this.requirePerson(ownerId, input.payerPersonId);
    input.allocations.forEach((allocation) => this.requirePerson(ownerId, allocation.personId));
    for (const evidenceId of input.evidenceIds ?? []) {
      const asset = this.evidence.get(evidenceId);
      if (!asset || asset.ownerId !== ownerId) throw new ApiError(400, "evidence does not belong to this ledger", "invalid_evidence");
    }
    const key = `expense:${ownerId}:${input.clientRequestId}`, requestFingerprint = fingerprint(input), existing = this.requests.get(key);
    if (existing) {
      if (existing.fingerprint !== requestFingerprint) throw new ApiError(409, "clientRequestId was already used with different data", "idempotency_conflict");
      return structuredClone(existing.value as Expense);
    }
    const expense: Expense = { ...structuredClone(input), items: structuredClone(input.items ?? []), evidenceIds: [...(input.evidenceIds ?? [])], id: randomUUID(), ownerId, creatorId: ownerId, createdAt: new Date().toISOString() };
    this.expenses.get(ownerId)!.push(expense); ledger.version += 1; this.requests.set(key, { fingerprint: requestFingerprint, value: expense });
    return structuredClone(expense);
  }

  async createPayment(ownerId: UUID, input: CreatePaymentInput): Promise<Payment> {
    const ledger = this.requireOwner(ownerId); validatePayment(input);
    this.requirePerson(ownerId, input.fromPersonId); this.requirePerson(ownerId, input.toPersonId);
    const key = `payment:${ownerId}:${input.clientRequestId}`, requestFingerprint = fingerprint(input), existing = this.requests.get(key);
    if (existing) {
      if (existing.fingerprint !== requestFingerprint) throw new ApiError(409, "clientRequestId was already used with different data", "idempotency_conflict");
      return structuredClone(existing.value as Payment);
    }
    const payment: Payment = { ...structuredClone(input), id: randomUUID(), ownerId, recorderId: ownerId, createdAt: new Date().toISOString() };
    this.payments.get(ownerId)!.push(payment); ledger.version += 1; this.requests.set(key, { fingerprint: requestFingerprint, value: payment });
    return structuredClone(payment);
  }

  async getSnapshot(ownerId: UUID, filterId?: UUID): Promise<LedgerSnapshot> {
    const ledger = this.requireOwner(ownerId), people = await this.listPeople(ownerId), savedFilters = await this.listSavedFilters(ownerId);
    let expenses = structuredClone(this.expenses.get(ownerId)!); let payments = structuredClone(this.payments.get(ownerId)!);
    const balances = calculateBalances(people.map((person) => person.id), expenses, payments);
    if (filterId) {
      const filter = savedFilters.find((item) => item.id === filterId);
      if (!filter) throw new ApiError(404, "saved filter not found", "not_found");
      const selected = new Set(filter.personIds);
      expenses = expenses.filter((expense) => selected.has(expense.payerPersonId) || expense.allocations.some((a) => selected.has(a.personId)));
      payments = payments.filter((payment) => selected.has(payment.fromPersonId) || selected.has(payment.toPersonId));
    }
    const snapshot: LedgerSnapshot = { version: ledger.version, currency: ledger.currency, people, savedFilters, expenses, payments, balances };
    if (filterId) snapshot.appliedFilterId = filterId;
    return snapshot;
  }

  private requireOwner(ownerId: UUID): Ledger { const ledger = this.ledgers.get(ownerId); if (!ledger) throw new ApiError(404, "profile not found", "not_found"); return ledger; }
  private requirePerson(ownerId: UUID, personId: UUID): Person { const person = this.people.get(ownerId)?.find((item) => item.id === personId); if (!person) throw new ApiError(422, "person does not belong to this ledger", "invalid_person"); return person; }
}

function validName(value: string, field: string): string { const trimmed = value.trim(); if (!trimmed || trimmed.length > 100) throw new ApiError(400, `${field} must contain 1–100 characters`, "invalid_input"); return trimmed; }
