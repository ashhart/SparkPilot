CREATE TRIGGER IF NOT EXISTS devices_owner_guard
BEFORE UPDATE OF role, revoked_at ON devices
WHEN OLD.role = 'owner'
BEGIN
  SELECT CASE
    WHEN (
      SELECT COUNT(*) FROM devices
      WHERE role = 'owner'
        AND revoked_at IS NULL
        AND id <> OLD.id
    ) = 0
    THEN RAISE(ABORT, 'cannot remove last active owner')
  END;
END;

-- Deletion must preserve an active owner because only an existing owner can invite another.
CREATE TRIGGER IF NOT EXISTS devices_owner_delete_guard
BEFORE DELETE ON devices
WHEN OLD.role = 'owner' AND OLD.revoked_at IS NULL
BEGIN
  SELECT CASE
    WHEN (
      SELECT COUNT(*) FROM devices
      WHERE role = 'owner'
        AND revoked_at IS NULL
        AND id <> OLD.id
    ) = 0
    THEN RAISE(ABORT, 'cannot remove last active owner')
  END;
END;

