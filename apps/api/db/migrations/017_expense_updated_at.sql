BEGIN;

-- Saved expenses can now have their amounts edited by their creator or payer. updated_at is moved forward by every edit,
-- so an edit made against an older version of the expense can be refused. Existing expenses haven't been edited
-- since they were created, so it starts at created_at.
ALTER TABLE expenses ADD COLUMN updated_at timestamptz;
UPDATE expenses SET updated_at = created_at;
ALTER TABLE expenses ALTER COLUMN updated_at SET DEFAULT now(), ALTER COLUMN updated_at SET NOT NULL;

COMMIT;
