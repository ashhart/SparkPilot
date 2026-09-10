-- One run of an automation at a time, whatever triggered it: storage refuses the second claim rather than timing deciding it.
CREATE UNIQUE INDEX IF NOT EXISTS automation_runs_in_flight
    ON automation_runs(automation_id)
    WHERE state = 'running';
