-- A lease carries a fence that only ever rises, so a worker whose lease was taken from it cannot write a terminal state afterwards.
ALTER TABLE operations ADD COLUMN lease_fence INTEGER NOT NULL DEFAULT 0;
