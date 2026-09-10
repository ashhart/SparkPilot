-- Persist automatic profile retry counts separately from measured peaks, unsafe state and failure codes.

ALTER TABLE model_profiles ADD COLUMN auto_retries INTEGER NOT NULL DEFAULT 0;
