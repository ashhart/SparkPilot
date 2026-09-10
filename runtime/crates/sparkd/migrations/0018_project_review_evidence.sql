-- Bind project review and merge decisions to one immutable evidence document.
ALTER TABLE changes ADD COLUMN head_commit TEXT;
ALTER TABLE changes ADD COLUMN protected_head_commit TEXT;
ALTER TABLE changes ADD COLUMN review_digest TEXT;
ALTER TABLE changes ADD COLUMN review_evidence_json TEXT NOT NULL DEFAULT '{}';
ALTER TABLE changes ADD COLUMN merged_commit TEXT;

CREATE INDEX IF NOT EXISTS changes_review_digest_idx
  ON changes(project_id, review_digest)
  WHERE review_digest IS NOT NULL;
