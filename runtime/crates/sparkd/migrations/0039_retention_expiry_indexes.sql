CREATE INDEX IF NOT EXISTS pairing_challenges_expiry_idx ON pairing_challenges(expires_at);
CREATE INDEX IF NOT EXISTS idempotency_records_expiry_idx ON idempotency_records(expires_at);
