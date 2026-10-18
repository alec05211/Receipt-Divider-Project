BEGIN;

-- Every account now has a dev account, created with it, so developers can test with their friends' dev accounts.
-- Only developers can act as theirs. A dev account mirrors its owner's names and profile picture, and dev accounts are
-- friends exactly when their owners are.
CREATE FUNCTION create_dev_profile() RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  INSERT INTO user_profiles (id, dev_owner_id, first_name, last_name, username, avatar_content_type, avatar_data, avatar_etag, avatar_updated_at)
  VALUES (gen_random_uuid(), NEW.id, NEW.first_name, NEW.last_name, NEW.username || '_dev', NEW.avatar_content_type, NEW.avatar_data, NEW.avatar_etag, NEW.avatar_updated_at)
  ON CONFLICT (dev_owner_id) DO NOTHING;
  INSERT INTO user_settings (user_id) SELECT id FROM user_profiles WHERE dev_owner_id=NEW.id ON CONFLICT (user_id) DO NOTHING;
  RETURN NULL;
END $$;
CREATE TRIGGER user_profiles_create_dev_profile AFTER INSERT ON user_profiles
  FOR EACH ROW WHEN (NEW.dev_owner_id IS NULL) EXECUTE FUNCTION create_dev_profile();

CREATE OR REPLACE FUNCTION sync_dev_profile() RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  UPDATE user_profiles SET first_name=NEW.first_name, last_name=NEW.last_name, username=NEW.username || '_dev',
    avatar_content_type=NEW.avatar_content_type, avatar_data=NEW.avatar_data, avatar_etag=NEW.avatar_etag,
    avatar_updated_at=NEW.avatar_updated_at, updated_at=now()
  WHERE dev_owner_id=NEW.id;
  RETURN NULL;
END $$;
DROP TRIGGER user_profiles_sync_dev_profile ON user_profiles;
CREATE TRIGGER user_profiles_sync_dev_profile
  AFTER UPDATE OF first_name, last_name, username, avatar_content_type, avatar_data, avatar_etag ON user_profiles
  FOR EACH ROW WHEN (NEW.dev_owner_id IS NULL) EXECUTE FUNCTION sync_dev_profile();

CREATE OR REPLACE FUNCTION sync_dev_friendships() RETURNS void LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  DELETE FROM friend_requests f USING user_profiles a, user_profiles b
  WHERE a.id=f.requester_id AND b.id=f.addressee_id AND (a.dev_owner_id IS NOT NULL OR b.dev_owner_id IS NOT NULL)
    AND NOT (a.dev_owner_id IS NOT NULL AND b.dev_owner_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM friend_requests r WHERE r.status='accepted'
        AND r.pair_low=least(a.dev_owner_id, b.dev_owner_id) AND r.pair_high=greatest(a.dev_owner_id, b.dev_owner_id)));
  INSERT INTO friend_requests (requester_id, addressee_id, status, responded_at)
  SELECT da.id, db.id, 'accepted', now() FROM friend_requests r
  JOIN user_profiles da ON da.dev_owner_id=r.requester_id JOIN user_profiles db ON db.dev_owner_id=r.addressee_id
  WHERE r.status='accepted'
  ON CONFLICT (pair_low, pair_high) DO NOTHING;
END $$;
-- Friendships no longer depend on the developer flag.
DROP TRIGGER user_profiles_sync_dev_friendships ON user_profiles;

-- Backfill: a dev account for every account without one, every dev account's picture, and their friendships.
INSERT INTO user_profiles (id, dev_owner_id, first_name, last_name, username, avatar_content_type, avatar_data, avatar_etag, avatar_updated_at)
SELECT gen_random_uuid(), o.id, o.first_name, o.last_name, o.username || '_dev', o.avatar_content_type, o.avatar_data, o.avatar_etag, o.avatar_updated_at
FROM user_profiles o WHERE o.dev_owner_id IS NULL AND NOT EXISTS (SELECT 1 FROM user_profiles d WHERE d.dev_owner_id=o.id);
UPDATE user_profiles d SET avatar_content_type=o.avatar_content_type, avatar_data=o.avatar_data, avatar_etag=o.avatar_etag, avatar_updated_at=o.avatar_updated_at
FROM user_profiles o WHERE d.dev_owner_id=o.id;
INSERT INTO user_settings (user_id) SELECT id FROM user_profiles WHERE dev_owner_id IS NOT NULL ON CONFLICT (user_id) DO NOTHING;
SELECT sync_dev_friendships();

COMMIT;
