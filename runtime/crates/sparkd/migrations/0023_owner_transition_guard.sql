-- Guard only transitions away from active ownership so renames and unchanged roles remain valid.
DROP TRIGGER IF EXISTS devices_owner_guard;
CREATE TRIGGER devices_owner_guard
BEFORE UPDATE OF role, revoked_at ON devices
WHEN OLD.role = 'owner' AND OLD.revoked_at IS NULL
 AND (NEW.role <> 'owner' OR NEW.revoked_at IS NOT NULL)
BEGIN
  SELECT CASE WHEN (
    SELECT COUNT(*) FROM devices
    WHERE role = 'owner' AND revoked_at IS NULL AND id <> OLD.id
  ) = 0 THEN RAISE(ABORT, 'cannot remove last active owner') END;
END;
