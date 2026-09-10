-- Prevent deletion of the final active owner because invitation issuance requires an existing owner.
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
