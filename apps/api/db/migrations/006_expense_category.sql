BEGIN;

-- An expense can be labeled with what it was for. Existing expenses have no category and keep a null.
ALTER TABLE expenses ADD COLUMN category text
  CHECK (category IN ('groceries','restaurant','movie','concert'));

COMMIT;
