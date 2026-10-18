BEGIN;

-- Deleting an expense voids it rather than removing it: it stays on record for everyone on it, stops counting toward
-- balances, and its payer can restore it. These record when it was voided and by whom; both are null while active.
ALTER TABLE expenses
  ADD COLUMN voided_at timestamptz,
  ADD COLUMN voided_by uuid REFERENCES user_profiles(id);
ALTER TABLE expenses ADD CONSTRAINT expenses_voided_consistent
  CHECK ((status = 'voided') = (voided_at IS NOT NULL AND voided_by IS NOT NULL));

COMMIT;
