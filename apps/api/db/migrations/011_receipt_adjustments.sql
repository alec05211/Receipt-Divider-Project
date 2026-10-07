BEGIN;

-- An item's offset now has two parts: the local offset is what the receipt ties to that item (its own discount), and
-- the global offset is its share of receipt-wide discounts, taxes and surcharges. Earlier offsets mixed both and can't
-- be separated, so they become global.
ALTER TABLE expense_items RENAME COLUMN offset_cents TO global_offset_cents;
ALTER TABLE expense_items
  ADD COLUMN local_offset_cents bigint NOT NULL DEFAULT 0,
  -- A tip row is split evenly among its owners rather than priced like an item.
  ADD COLUMN kind text NOT NULL DEFAULT 'item' CHECK (kind IN ('item', 'tip')),
  ADD COLUMN taxed boolean NOT NULL DEFAULT true;

-- Receipt-wide adjustments in the order the receipt applies them. `rate` is a fraction of the running cost of the rows
-- it applies to (0.06 for 6% tax); a tip has no rate. `amount_cents` is what the adjustment came to in this expense.
CREATE TABLE expense_adjustments (
  expense_id uuid NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
  position integer NOT NULL CHECK (position >= 0),
  kind text NOT NULL CHECK (kind IN ('discount', 'tax', 'tip', 'surcharge')),
  amount_cents bigint NOT NULL CHECK (amount_cents >= 0),
  rate numeric(9, 6),
  PRIMARY KEY (expense_id, position)
);
ALTER TABLE expense_adjustments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON expense_adjustments FROM anon, authenticated;

COMMIT;
