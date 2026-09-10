-- PLAN 32.3: a measured peak is evidence only about the engine image, model revision, runtime and driver that produced it; existing rows carry no environment, so their peaks stop being admission evidence until the next load re-measures them.

ALTER TABLE model_profiles ADD COLUMN measured_environment TEXT;
