CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE user_profiles (
    id uuid PRIMARY KEY,
    display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 100),
    avatar_content_type text,
    avatar_data bytea,
    avatar_etag text,
    avatar_updated_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((avatar_data IS NULL) = (avatar_content_type IS NULL)),
    CHECK (avatar_data IS NULL OR octet_length(avatar_data) <= 5242880)
);

CREATE TABLE groups (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
    currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
    created_by uuid NOT NULL REFERENCES user_profiles(id),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE memberships (
    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES user_profiles(id),
    role text NOT NULL CHECK (role IN ('owner', 'member')),
    state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'left', 'removed')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, user_id)
);

CREATE TABLE receipts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id uuid NOT NULL,
    uploaded_by uuid NOT NULL,
    content_type text NOT NULL CHECK (content_type IN ('image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/webp')),
    image_data bytea NOT NULL CHECK (octet_length(image_data) BETWEEN 1 AND 15728640),
    image_etag text NOT NULL,
    extraction_status text NOT NULL DEFAULT 'not_requested' CHECK (extraction_status IN ('not_requested', 'pending', 'complete', 'failed')),
    extracted_data jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (group_id, uploaded_by) REFERENCES memberships(group_id, user_id)
);
CREATE INDEX receipts_group_created_idx ON receipts(group_id, created_at DESC);

CREATE TABLE expenses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id uuid NOT NULL REFERENCES groups(id),
    creator_id uuid NOT NULL,
    payer_id uuid NOT NULL,
    receipt_id uuid REFERENCES receipts(id),
    client_request_id uuid NOT NULL,
    request_fingerprint text NOT NULL,
    description text NOT NULL CHECK (char_length(description) BETWEEN 1 AND 200),
    currency text NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    total_cents bigint NOT NULL CHECK (total_cents > 0),
    transaction_date date NOT NULL,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'void')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (creator_id, client_request_id),
    FOREIGN KEY (group_id, creator_id) REFERENCES memberships(group_id, user_id),
    FOREIGN KEY (group_id, payer_id) REFERENCES memberships(group_id, user_id)
);
CREATE INDEX expenses_group_date_idx ON expenses(group_id, transaction_date DESC, created_at DESC, id);

CREATE TABLE expense_items (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    expense_id uuid NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
    position integer NOT NULL CHECK (position >= 0),
    name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 300),
    amount_cents bigint NOT NULL CHECK (amount_cents > 0),
    offset_cents bigint NOT NULL DEFAULT 0,
    UNIQUE (expense_id, position)
);

CREATE TABLE expense_allocations (
    expense_id uuid NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
    group_id uuid NOT NULL,
    user_id uuid NOT NULL,
    amount_cents bigint NOT NULL CHECK (amount_cents >= 0),
    PRIMARY KEY (expense_id, user_id),
    FOREIGN KEY (group_id, user_id) REFERENCES memberships(group_id, user_id)
);

CREATE TABLE repayments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id uuid NOT NULL REFERENCES groups(id),
    recorder_id uuid NOT NULL,
    from_user_id uuid NOT NULL,
    to_user_id uuid NOT NULL,
    client_request_id uuid NOT NULL,
    request_fingerprint text NOT NULL,
    amount_cents bigint NOT NULL CHECK (amount_cents > 0),
    transaction_date date NOT NULL,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'void')),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (recorder_id, client_request_id),
    CHECK (from_user_id <> to_user_id),
    FOREIGN KEY (group_id, recorder_id) REFERENCES memberships(group_id, user_id),
    FOREIGN KEY (group_id, from_user_id) REFERENCES memberships(group_id, user_id),
    FOREIGN KEY (group_id, to_user_id) REFERENCES memberships(group_id, user_id)
);
CREATE INDEX repayments_group_date_idx ON repayments(group_id, transaction_date DESC, created_at DESC, id);

CREATE TABLE audit_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    group_id uuid NOT NULL REFERENCES groups(id),
    actor_id uuid NOT NULL REFERENCES user_profiles(id),
    group_version bigint NOT NULL,
    event_type text NOT NULL,
    entity_id uuid NOT NULL,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (group_id, group_version)
);

-- Cross-row invariants (item totals and allocation totals) are checked by the API transaction.
-- The ledger rows remain authoritative; groups.version is only a synchronization cursor.
