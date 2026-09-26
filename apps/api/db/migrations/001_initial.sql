BEGIN;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE user_profiles (
  id uuid PRIMARY KEY,
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 100),
  avatar_content_type text,
  avatar_data bytea,
  avatar_etag text,
  avatar_updated_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((avatar_data IS NULL) = (avatar_content_type IS NULL)),
  CHECK (avatar_data IS NULL OR octet_length(avatar_data) <= 5242880)
);

CREATE TABLE ledgers (
  owner_id uuid PRIMARY KEY REFERENCES user_profiles(id) ON DELETE CASCADE,
  currency char(3) NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE people (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES ledgers(owner_id) ON DELETE CASCADE,
  display_name text NOT NULL CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 100),
  linked_user_id uuid REFERENCES user_profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_id, id)
);
CREATE UNIQUE INDEX people_linked_user_idx ON people (owner_id, linked_user_id) WHERE linked_user_id IS NOT NULL;

CREATE TABLE saved_filters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES ledgers(owner_id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 100),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_id, id),
  UNIQUE (owner_id, name)
);

CREATE TABLE saved_filter_people (
  owner_id uuid NOT NULL,
  filter_id uuid NOT NULL,
  person_id uuid NOT NULL,
  PRIMARY KEY (filter_id, person_id),
  FOREIGN KEY (owner_id, filter_id) REFERENCES saved_filters(owner_id, id) ON DELETE CASCADE,
  FOREIGN KEY (owner_id, person_id) REFERENCES people(owner_id, id) ON DELETE CASCADE
);

CREATE TYPE evidence_kind AS ENUM ('receipt', 'restaurant_check', 'ticket_confirmation', 'other');
CREATE TABLE evidence_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES ledgers(owner_id) ON DELETE CASCADE,
  uploaded_by uuid NOT NULL REFERENCES user_profiles(id),
  kind evidence_kind NOT NULL,
  content_type text NOT NULL CHECK (content_type IN ('image/jpeg','image/png','image/heic','image/heif','image/webp')),
  image_data bytea NOT NULL CHECK (octet_length(image_data) BETWEEN 1 AND 15728640),
  image_etag text NOT NULL,
  extraction_status text NOT NULL DEFAULT 'not_requested' CHECK (extraction_status IN ('not_requested','pending','complete','failed')),
  extracted_data jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_id, id)
);

CREATE TABLE expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES ledgers(owner_id) ON DELETE CASCADE,
  creator_id uuid NOT NULL REFERENCES user_profiles(id),
  payer_person_id uuid NOT NULL,
  client_request_id uuid NOT NULL,
  request_fingerprint text NOT NULL,
  description text NOT NULL CHECK (char_length(btrim(description)) BETWEEN 1 AND 200),
  currency char(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
  total_cents bigint NOT NULL CHECK (total_cents > 0),
  transaction_date date NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','voided')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_id, id),
  UNIQUE (owner_id, client_request_id),
  FOREIGN KEY (owner_id, payer_person_id) REFERENCES people(owner_id, id)
);

CREATE TABLE expense_items (
  owner_id uuid NOT NULL,
  expense_id uuid NOT NULL,
  position integer NOT NULL CHECK (position >= 0),
  name text NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 300),
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  offset_cents bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (expense_id, position),
  FOREIGN KEY (owner_id, expense_id) REFERENCES expenses(owner_id, id) ON DELETE CASCADE
);

CREATE TABLE expense_allocations (
  owner_id uuid NOT NULL,
  expense_id uuid NOT NULL,
  person_id uuid NOT NULL,
  amount_cents bigint NOT NULL CHECK (amount_cents >= 0),
  PRIMARY KEY (expense_id, person_id),
  FOREIGN KEY (owner_id, expense_id) REFERENCES expenses(owner_id, id) ON DELETE CASCADE,
  FOREIGN KEY (owner_id, person_id) REFERENCES people(owner_id, id)
);

CREATE TABLE expense_evidence (
  owner_id uuid NOT NULL,
  expense_id uuid NOT NULL,
  evidence_id uuid NOT NULL,
  position integer NOT NULL CHECK (position >= 0),
  PRIMARY KEY (expense_id, evidence_id),
  UNIQUE (expense_id, position),
  FOREIGN KEY (owner_id, expense_id) REFERENCES expenses(owner_id, id) ON DELETE CASCADE,
  FOREIGN KEY (owner_id, evidence_id) REFERENCES evidence_assets(owner_id, id)
);

CREATE TABLE repayments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES ledgers(owner_id) ON DELETE CASCADE,
  recorder_id uuid NOT NULL REFERENCES user_profiles(id),
  from_person_id uuid NOT NULL,
  to_person_id uuid NOT NULL,
  client_request_id uuid NOT NULL,
  request_fingerprint text NOT NULL,
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  transaction_date date NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','voided')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_id, client_request_id),
  CHECK (from_person_id <> to_person_id),
  FOREIGN KEY (owner_id, from_person_id) REFERENCES people(owner_id, id),
  FOREIGN KEY (owner_id, to_person_id) REFERENCES people(owner_id, id)
);

CREATE TABLE audit_events (
  id bigserial PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES ledgers(owner_id) ON DELETE CASCADE,
  actor_id uuid NOT NULL REFERENCES user_profiles(id),
  ledger_version bigint NOT NULL CHECK (ledger_version > 0),
  event_type text NOT NULL,
  entity_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_id, ledger_version)
);

CREATE INDEX expenses_feed_idx ON expenses (owner_id, transaction_date DESC, created_at DESC);
CREATE INDEX repayments_feed_idx ON repayments (owner_id, transaction_date DESC, created_at DESC);
CREATE INDEX allocations_person_idx ON expense_allocations (owner_id, person_id);
CREATE INDEX evidence_owner_idx ON evidence_assets (owner_id, created_at DESC);

-- Clients never access these tables directly. Supabase Auth JWTs terminate at the API,
-- and the API connects with a dedicated backend role through the transaction pooler.
ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledgers ENABLE ROW LEVEL SECURITY;
ALTER TABLE people ENABLE ROW LEVEL SECURITY;
ALTER TABLE saved_filters ENABLE ROW LEVEL SECURITY;
ALTER TABLE saved_filter_people ENABLE ROW LEVEL SECURITY;
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
