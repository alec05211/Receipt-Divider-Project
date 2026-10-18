BEGIN;

-- A developer can act as their dev account from the same sign-in. It is its own profile, pointing at the developer's,
-- and has no credentials. Its names follow the owner's; its username is the owner's plus "_dev", and only dev accounts
-- may end a username that way.
ALTER TABLE user_profiles ADD COLUMN dev_owner_id uuid UNIQUE REFERENCES user_profiles(id) ON DELETE CASCADE;
ALTER TABLE user_profiles ADD CONSTRAINT user_profiles_dev_owner_check CHECK (dev_owner_id IS NULL OR dev_owner_id <> id);

ALTER TABLE user_profiles DROP CONSTRAINT user_profiles_username_check;
ALTER TABLE user_profiles ADD CONSTRAINT user_profiles_username_check CHECK (username IS NULL OR CASE
  WHEN dev_owner_id IS NULL THEN username ~ '^[a-z0-9_]{3,24}$' AND username !~ '_dev$'
  ELSE username ~ '^[a-z0-9_]{3,24}_dev$' END);

ALTER TABLE user_profiles DROP COLUMN display_name;
ALTER TABLE user_profiles
  ADD COLUMN display_name text GENERATED ALWAYS AS (
    CASE WHEN first_name IS NULL OR last_name IS NULL THEN NULL
      WHEN dev_owner_id IS NULL THEN first_name || ' ' || last_name
      ELSE first_name || ' ' || last_name || ' (Dev)' END
  ) STORED;

CREATE FUNCTION sync_dev_profile() RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  UPDATE user_profiles SET first_name=NEW.first_name, last_name=NEW.last_name, username=NEW.username || '_dev', updated_at=now()
  WHERE dev_owner_id=NEW.id;
  RETURN NULL;
END $$;
CREATE TRIGGER user_profiles_sync_dev_profile AFTER UPDATE OF first_name, last_name, username ON user_profiles
  FOR EACH ROW WHEN (NEW.dev_owner_id IS NULL) EXECUTE FUNCTION sync_dev_profile();

-- Dev accounts are friends exactly when their owners are friends and both are still developers. They have no other
-- friendships, so any other row involving one is removed.
CREATE FUNCTION sync_dev_friendships() RETURNS void LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  DELETE FROM friend_requests f USING user_profiles a, user_profiles b
  WHERE a.id=f.requester_id AND b.id=f.addressee_id AND (a.dev_owner_id IS NOT NULL OR b.dev_owner_id IS NOT NULL)
    AND NOT (a.dev_owner_id IS NOT NULL AND b.dev_owner_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM friend_requests r JOIN user_profiles oa ON oa.id=a.dev_owner_id JOIN user_profiles ob ON ob.id=b.dev_owner_id
      WHERE r.status='accepted' AND oa.is_developer AND ob.is_developer
        AND r.pair_low=least(oa.id, ob.id) AND r.pair_high=greatest(oa.id, ob.id)));
  INSERT INTO friend_requests (requester_id, addressee_id, status, responded_at)
  SELECT da.id, db.id, 'accepted', now() FROM friend_requests r
  JOIN user_profiles oa ON oa.id=r.requester_id JOIN user_profiles ob ON ob.id=r.addressee_id
  JOIN user_profiles da ON da.dev_owner_id=oa.id JOIN user_profiles db ON db.dev_owner_id=ob.id
  WHERE r.status='accepted' AND oa.is_developer AND ob.is_developer
  ON CONFLICT (pair_low, pair_high) DO NOTHING;
END $$;

CREATE FUNCTION sync_dev_friendships_trigger() RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF pg_trigger_depth() > 1 THEN RETURN NULL; END IF;
  PERFORM sync_dev_friendships();
  RETURN NULL;
END $$;
CREATE TRIGGER friend_requests_sync_dev AFTER INSERT OR UPDATE OR DELETE ON friend_requests
  FOR EACH STATEMENT EXECUTE FUNCTION sync_dev_friendships_trigger();
CREATE TRIGGER user_profiles_sync_dev_friendships AFTER UPDATE OF is_developer ON user_profiles
  FOR EACH STATEMENT EXECUTE FUNCTION sync_dev_friendships_trigger();

COMMIT;
