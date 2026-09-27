BEGIN;

-- The display name is always "First Last"; derive it so it can't drift from the name fields.
-- Profiles that haven't set their name yet have no display name.
ALTER TABLE user_profiles DROP COLUMN display_name;
ALTER TABLE user_profiles
  ADD COLUMN display_name text GENERATED ALWAYS AS (
    CASE WHEN first_name IS NULL OR last_name IS NULL THEN NULL ELSE first_name || ' ' || last_name END
  ) STORED;

COMMIT;
