-- Enforce at most one durable owner per immutable container ID to prevent concurrent adoption.
CREATE UNIQUE INDEX IF NOT EXISTS inference_container_id_unique_idx
  ON inference_instances(container_id)
  WHERE container_id IS NOT NULL;
