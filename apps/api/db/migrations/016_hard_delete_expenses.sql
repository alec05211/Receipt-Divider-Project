BEGIN;

-- Deleting an expense now removes it and everything tied to it instead of voiding it (migration 015). Remove any
-- expense already voided the same way: its revision history, the expense (items, item owners, adjustments,
-- allocations, and evidence links cascade), and any receipt image no remaining expense shows.
CREATE TEMP TABLE voided_expenses ON COMMIT DROP AS SELECT id FROM expenses WHERE status = 'voided';
CREATE TEMP TABLE voided_evidence ON COMMIT DROP AS
  SELECT DISTINCT evidence_id FROM expense_evidence WHERE expense_id IN (SELECT id FROM voided_expenses);
DELETE FROM audit_events WHERE entity_id IN (SELECT id FROM voided_expenses);
DELETE FROM expenses WHERE id IN (SELECT id FROM voided_expenses);
DELETE FROM evidence_assets a WHERE a.id IN (SELECT evidence_id FROM voided_evidence)
  AND NOT EXISTS (SELECT 1 FROM expense_evidence ee WHERE ee.evidence_id = a.id);

ALTER TABLE expenses DROP CONSTRAINT IF EXISTS expenses_voided_consistent;
ALTER TABLE expenses DROP COLUMN IF EXISTS voided_at, DROP COLUMN IF EXISTS voided_by;

COMMIT;
