ALTER TABLE pairing_invitations ADD COLUMN join_code_hash BLOB;

CREATE INDEX pairing_invites_join_code_idx
  ON pairing_invitations(join_code_hash, expires_at, consumed_at, revoked_at);
