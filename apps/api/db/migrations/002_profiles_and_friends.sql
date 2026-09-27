BEGIN;

ALTER TABLE user_profiles
  ADD COLUMN IF NOT EXISTS first_name text,
  ADD COLUMN IF NOT EXISTS last_name text,
  ADD COLUMN IF NOT EXISTS username text;

ALTER TABLE user_profiles
  ADD CONSTRAINT user_profiles_first_name_check CHECK (first_name IS NULL OR char_length(btrim(first_name)) BETWEEN 1 AND 60),
  ADD CONSTRAINT user_profiles_last_name_check CHECK (last_name IS NULL OR char_length(btrim(last_name)) BETWEEN 1 AND 60),
  ADD CONSTRAINT user_profiles_username_check CHECK (username IS NULL OR username ~ '^[a-z0-9_]{3,24}$');

CREATE UNIQUE INDEX IF NOT EXISTS user_profiles_username_unique_idx ON user_profiles (lower(username)) WHERE username IS NOT NULL;

CREATE TABLE friend_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_id uuid NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  addressee_id uuid NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted')),
  created_at timestamptz NOT NULL DEFAULT now(),
  responded_at timestamptz,
  pair_low uuid GENERATED ALWAYS AS (least(requester_id, addressee_id)) STORED,
  pair_high uuid GENERATED ALWAYS AS (greatest(requester_id, addressee_id)) STORED,
  CHECK (requester_id <> addressee_id),
  UNIQUE (pair_low, pair_high)
);

ALTER TABLE friend_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON friend_requests FROM anon, authenticated;

COMMIT;
