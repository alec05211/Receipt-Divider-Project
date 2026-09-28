BEGIN;

-- Developer accounts can reset every expense and payment from the app. Set this by hand; the API never changes it.
ALTER TABLE user_profiles ADD COLUMN is_developer boolean NOT NULL DEFAULT false;

COMMIT;
