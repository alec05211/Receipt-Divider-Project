BEGIN;

-- Percent is now the product default. Existing accounts used the former implicit dollar default,
-- so move them to the new baseline while keeping the setting editable afterward.
ALTER TABLE user_settings ALTER COLUMN slider_unit SET DEFAULT 'percent';
UPDATE user_settings SET slider_unit = 'percent' WHERE slider_unit = 'dollars';

COMMIT;
