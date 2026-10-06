BEGIN;

-- Who had each item. Ownership is a plain yes/no record; what each person owes stays in expense_allocations.
CREATE TABLE expense_item_owners (
  expense_id uuid NOT NULL,
  position integer NOT NULL,
  user_id uuid NOT NULL REFERENCES user_profiles(id),
  PRIMARY KEY (expense_id, position, user_id),
  FOREIGN KEY (expense_id, position) REFERENCES expense_items(expense_id, position) ON DELETE CASCADE
);
CREATE INDEX expense_item_owners_user_idx ON expense_item_owners (user_id);
ALTER TABLE expense_item_owners ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON expense_item_owners FROM anon, authenticated;

-- Every expense now has at least one item. Split-total expenses were saved without items, so each gets one
-- item for its total.
INSERT INTO expense_items (expense_id, position, name, amount_cents, offset_cents)
SELECT e.id, 0, e.description, e.total_cents, 0
FROM expenses e
WHERE NOT EXISTS (SELECT 1 FROM expense_items i WHERE i.expense_id = e.id);

-- Who had which item wasn't recorded before, so everyone on an existing expense owns each of its items.
INSERT INTO expense_item_owners (expense_id, position, user_id)
SELECT i.expense_id, i.position, a.user_id
FROM expense_items i
JOIN expense_allocations a ON a.expense_id = i.expense_id;

COMMIT;
