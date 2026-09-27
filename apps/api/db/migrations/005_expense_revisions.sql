BEGIN;

-- Audit events can now say what changed, so an edit such as renaming an expense keeps the value it replaced.
-- Existing events (creations) have nothing to add and keep a null.
ALTER TABLE audit_events ADD COLUMN details jsonb;

COMMIT;
