BEGIN;

-- Expenses stopped belonging to a ledger in 004, leaving one row per account that only holds its currency.
-- Name it for what it is and keep account-wide preferences here. saved_filters' foreign key follows the rename.
ALTER TABLE ledgers RENAME TO user_settings;
ALTER TABLE user_settings RENAME COLUMN owner_id TO user_id;
ALTER TABLE user_settings RENAME CONSTRAINT ledgers_pkey TO user_settings_pkey;

-- Whether contribution sliders are entered in dollars or percent; previously stored only on the phone.
ALTER TABLE user_settings ADD COLUMN slider_unit text NOT NULL DEFAULT 'dollars'
  CHECK (slider_unit IN ('dollars','percent'));

COMMIT;
