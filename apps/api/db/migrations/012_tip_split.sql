BEGIN;

-- Whether starting contributions split a receipt's tip evenly among everyone on the expense or in proportion to what
-- each person had. Even was the only behavior until now, so it stays the default.
ALTER TABLE user_settings ADD COLUMN tip_split text NOT NULL DEFAULT 'even'
  CHECK (tip_split IN ('even','proportional'));

COMMIT;
