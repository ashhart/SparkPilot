-- A place in the Spark's rolling hour, taken before an outbound web request is made rather than after.
CREATE TABLE web_call_reservations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    made_at INTEGER NOT NULL
);
CREATE INDEX web_call_reservations_recent ON web_call_reservations(made_at);
