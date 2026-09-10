-- Existing grants remain paired but require registration of a separate presence key before elevated revocation.

ALTER TABLE devices ADD COLUMN presence_public_key_spki BLOB;
ALTER TABLE devices ADD COLUMN presence_public_key_fingerprint TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS devices_presence_key_idx
  ON devices(presence_public_key_fingerprint)
  WHERE presence_public_key_fingerprint IS NOT NULL;
