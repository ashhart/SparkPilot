CREATE TABLE household_members (
    device_id TEXT PRIMARY KEY REFERENCES devices(id),
    added_by TEXT NOT NULL REFERENCES devices(id),
    added_at TEXT NOT NULL
);

CREATE TABLE household_notes (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision > 0),
    author_device_id TEXT NOT NULL REFERENCES devices(id),
    author_name TEXT NOT NULL,
    updated_by_name TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT
);
CREATE INDEX household_notes_updated ON household_notes(updated_at, id);
