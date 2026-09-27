BEGIN;

-- Expenses and repayments are now shared between the accounts involved instead of living in one
-- account's private ledger of local "people". Everyone in the app is a user, so the people table goes.
-- The only data in the old tables was test data between placeholder people, so it is dropped with them.
DROP TABLE expense_evidence, expense_allocations, expense_items, expenses, repayments, audit_events,
  evidence_assets, saved_filter_people, saved_filters, people;
DROP TYPE evidence_kind;

-- The ledger row now only holds the account's currency.
ALTER TABLE ledgers DROP COLUMN version;

CREATE TABLE saved_filters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES ledgers(owner_id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_id, id),
  UNIQUE (owner_id, name)
);

CREATE TABLE saved_filter_members (
  owner_id uuid NOT NULL,
  filter_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  PRIMARY KEY (filter_id, user_id),
  FOREIGN KEY (owner_id, filter_id) REFERENCES saved_filters(owner_id, id) ON DELETE CASCADE
);

CREATE TYPE evidence_kind AS ENUM ('receipt', 'restaurant_check', 'ticket_confirmation', 'other');
CREATE TABLE evidence_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  uploaded_by uuid NOT NULL REFERENCES user_profiles(id),
  kind evidence_kind NOT NULL,
  content_type text NOT NULL CHECK (content_type IN ('image/jpeg','image/png','image/heic','image/heif','image/webp')),
  image_data bytea NOT NULL CHECK (octet_length(image_data) BETWEEN 1 AND 15728640),
  image_etag text NOT NULL,
  extraction_status text NOT NULL DEFAULT 'not_requested' CHECK (extraction_status IN ('not_requested','pending','complete','failed')),
  extracted_data jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Visible to its creator, its payer, and everyone with an allocation.
CREATE TABLE expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id uuid NOT NULL REFERENCES user_profiles(id),
  payer_id uuid NOT NULL REFERENCES user_profiles(id),
  client_request_id uuid NOT NULL,
  request_fingerprint text NOT NULL,
  description text NOT NULL CHECK (char_length(btrim(description)) BETWEEN 1 AND 200),
  currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  total_cents bigint NOT NULL CHECK (total_cents > 0),
  transaction_date date NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','voided')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (creator_id, client_request_id)
);

CREATE TABLE expense_items (
  expense_id uuid NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
  position integer NOT NULL CHECK (position >= 0),
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 300),
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  offset_cents bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (expense_id, position)
);

CREATE TABLE expense_allocations (
  expense_id uuid NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES user_profiles(id),
  amount_cents bigint NOT NULL CHECK (amount_cents >= 0),
  PRIMARY KEY (expense_id, user_id)
);

CREATE TABLE expense_evidence (
  expense_id uuid NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
  evidence_id uuid NOT NULL REFERENCES evidence_assets(id),
  position integer NOT NULL CHECK (position >= 0),
  PRIMARY KEY (expense_id, evidence_id),
  UNIQUE (expense_id, position)
);

-- Visible to the two people involved.
CREATE TABLE repayments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recorder_id uuid NOT NULL REFERENCES user_profiles(id),
  from_user_id uuid NOT NULL REFERENCES user_profiles(id),
  to_user_id uuid NOT NULL REFERENCES user_profiles(id),
  client_request_id uuid NOT NULL,
  request_fingerprint text NOT NULL,
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  transaction_date date NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','voided')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (recorder_id, client_request_id),
  CHECK (from_user_id <> to_user_id)
);

CREATE TABLE audit_events (
  id bigserial PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES user_profiles(id),
  event_type text NOT NULL,
  entity_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX expenses_payer_idx ON expenses (payer_id);
CREATE INDEX expense_allocations_user_idx ON expense_allocations (user_id);
CREATE INDEX expense_evidence_evidence_idx ON expense_evidence (evidence_id);
CREATE INDEX repayments_from_idx ON repayments (from_user_id);
CREATE INDEX repayments_to_idx ON repayments (to_user_id);
CREATE INDEX evidence_uploader_idx ON evidence_assets (uploaded_by, created_at DESC);

ALTER TABLE saved_filters ENABLE ROW LEVEL SECURITY;
ALTER TABLE saved_filter_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE evidence_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE expense_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE repayments ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;

COMMIT;
