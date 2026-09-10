//! Store provider secrets outside SQLite and return only credential references through APIs.

use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use rusqlite::{Connection, OptionalExtension};
use uuid::Uuid;

use crate::clock::{UtcClock, system_clock};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderCredentialRecord {
    pub id: Uuid,
    pub provider: String,
    pub display_name: String,
    pub created_at: String,
}

pub struct CredentialStore {
    base_dir: PathBuf,
    clock: Arc<dyn UtcClock>,
}

impl CredentialStore {
    pub fn new(data_dir: &Path) -> Self {
        Self {
            base_dir: data_dir.join("credentials"),
            clock: system_clock(),
        }
    }

    pub fn with_clock(data_dir: &Path, clock: Arc<dyn UtcClock>) -> Self {
        Self {
            base_dir: data_dir.join("credentials"),
            clock,
        }
    }

    fn secret_path(&self, id: Uuid) -> PathBuf {
        self.base_dir.join(format!("{id}.secret"))
    }

    /// Store a provider secret; returns the credential id.
    pub fn store(
        &self,
        conn: &Connection,
        provider: &str,
        display_name: &str,
        secret: &str,
        created_by: Uuid,
    ) -> Result<Uuid, String> {
        let id = Uuid::new_v4();
        let path = self.secret_path(id);
        std::fs::create_dir_all(&self.base_dir).map_err(|e| e.to_string())?;
        std::fs::set_permissions(&self.base_dir, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| e.to_string())?;
        // Create secret files exclusively with O_NOFOLLOW so existing symlinks cannot redirect writes or truncate another file.
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .custom_flags(libc::O_NOFOLLOW)
            .mode(0o600)
            .open(&path)
            .map_err(|e| e.to_string())?;
        use std::io::Write;
        let outcome = (|| {
            file.write_all(secret.as_bytes())
                .map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
            conn.execute(
                "INSERT INTO provider_credentials
                (id, provider, display_name, secret_reference, created_by_device_id,
                 created_at, last_used_at, revoked_at, metadata_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, NULL, '{}')",
                rusqlite::params![
                    id.to_string(),
                    provider,
                    display_name,
                    path.to_string_lossy(),
                    created_by.to_string(),
                    self.clock.now_rfc3339(),
                ],
            )
            .map_err(|e| e.to_string())?;
            Ok::<(), String>(())
        })();
        if let Err(error) = outcome {
            drop(file);
            std::fs::remove_file(&path).map_err(|cleanup| {
                format!("credential storage failed: {error}; cleanup failed: {cleanup}")
            })?;
            return Err(error);
        }
        Ok(id)
    }

    /// Resolve a credential's secret path (never the secret itself).
    pub fn resolve(&self, conn: &Connection, id: Uuid) -> Result<Option<PathBuf>, String> {
        let row: Option<(String, Option<String>)> = conn
            .query_row(
                "SELECT secret_reference, revoked_at FROM provider_credentials WHERE id = ?1",
                rusqlite::params![id.to_string()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(|e| e.to_string())?;
        let Some((reference, revoked_at)) = row else {
            return Ok(None);
        };
        if revoked_at.is_some() {
            return Ok(None);
        }
        let expected = self.secret_path(id);
        if Path::new(&reference) != expected.as_path() {
            return Err("provider credential reference does not match its protected path".into());
        }
        Ok(Some(expected))
    }

    /// Return the provider label without exposing the secret or its contents.
    pub fn provider(&self, conn: &Connection, id: Uuid) -> Result<Option<String>, String> {
        conn.query_row(
            "SELECT provider FROM provider_credentials
              WHERE id = ?1 AND revoked_at IS NULL",
            rusqlite::params![id.to_string()],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| error.to_string())
    }

    pub fn list(&self, conn: &Connection) -> Result<Vec<ProviderCredentialRecord>, String> {
        let mut statement = conn
            .prepare(
                "SELECT id, provider, display_name, created_at
                   FROM provider_credentials
                  WHERE revoked_at IS NULL
                  ORDER BY created_at DESC, id ASC
                  LIMIT 100",
            )
            .map_err(|error| error.to_string())?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })
            .map_err(|error| error.to_string())?;
        rows.map(|row| {
            let (id, provider, display_name, created_at) =
                row.map_err(|error| error.to_string())?;
            Ok(ProviderCredentialRecord {
                id: Uuid::parse_str(&id).map_err(|_| "stored credential id is invalid")?,
                provider,
                display_name,
                created_at,
            })
        })
        .collect()
    }

    pub fn revoke(&self, conn: &Connection, id: Uuid) -> Result<(), String> {
        conn.execute(
            "UPDATE provider_credentials SET revoked_at = ?1 WHERE id = ?2",
            rusqlite::params![self.clock.now_rfc3339(), id.to_string()],
        )
        .map_err(|e| e.to_string())?;
        match std::fs::remove_file(self.secret_path(id)) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.to_string()),
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clock::ManualUtcClock;
    use time::{OffsetDateTime, format_description::well_known::Rfc3339};

    #[test]
    fn a_failed_database_insert_leaves_no_secret_file() {
        let directory = tempfile::tempdir().unwrap();
        let connection = Connection::open_in_memory().unwrap();
        let store = CredentialStore::new(directory.path());
        assert!(
            store
                .store(
                    &connection,
                    "huggingface",
                    "test",
                    "private test value",
                    Uuid::new_v4()
                )
                .is_err()
        );
        assert_eq!(
            std::fs::read_dir(directory.path().join("credentials"))
                .unwrap()
                .count(),
            0
        );
    }

    #[test]
    fn secret_lives_in_0600_file_never_in_db_or_api() {
        let dir = tempfile::tempdir().unwrap();
        let mut conn = Connection::open_in_memory().unwrap();
        crate::migration::migrate(&mut conn).unwrap();
        let initial = OffsetDateTime::parse("2024-04-05T06:07:08Z", &Rfc3339).unwrap();
        let clock = Arc::new(ManualUtcClock::new(initial));
        let store = CredentialStore::with_clock(dir.path(), clock.clone());
        let actor = Uuid::new_v4();
        crate::store::insert_device(
            &conn,
            &actor,
            "t",
            "macos",
            b"spki",
            &format!("fp-{actor}"),
            "owner",
        )
        .unwrap();
        let id = store
            .store(
                &conn,
                "huggingface",
                "huggingface.co",
                "hf_secret_value",
                actor,
            )
            .unwrap();

        // The DB row must never contain the secret text.
        let row: String = conn
            .query_row(
                "SELECT secret_reference FROM provider_credentials WHERE id = ?1",
                rusqlite::params![id.to_string()],
                |r| r.get(0),
            )
            .unwrap();
        assert!(!row.contains("hf_secret_value"));

        let path = store.resolve(&conn, id).unwrap().unwrap();
        let meta = std::fs::metadata(&path).unwrap();
        assert_eq!(meta.permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "hf_secret_value");

        let created_at: String = conn
            .query_row(
                "SELECT created_at FROM provider_credentials WHERE id = ?1",
                [id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(created_at, "2024-04-05T06:07:08Z");

        clock.advance(time::Duration::seconds(9));
        store.revoke(&conn, id).unwrap();
        assert!(store.resolve(&conn, id).unwrap().is_none());
        assert!(!path.exists());
        let revoked_at: String = conn
            .query_row(
                "SELECT revoked_at FROM provider_credentials WHERE id = ?1",
                [id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(revoked_at, "2024-04-05T06:07:17Z");
        assert!(store.list(&conn).unwrap().is_empty());
    }

    #[test]
    fn list_returns_only_safe_active_metadata() {
        let directory = tempfile::tempdir().unwrap();
        let mut connection = Connection::open_in_memory().unwrap();
        crate::migration::migrate(&mut connection).unwrap();
        let actor = Uuid::new_v4();
        crate::store::insert_device(
            &connection,
            &actor,
            "owner",
            "ios",
            b"spki",
            &format!("fp-{actor}"),
            "owner",
        )
        .unwrap();
        let store = CredentialStore::new(directory.path());
        let id = store
            .store(
                &connection,
                "huggingface",
                "Private models",
                "hf_secret_must_never_be_listed",
                actor,
            )
            .unwrap();

        let records = store.list(&connection).unwrap();

        assert_eq!(records.len(), 1);
        assert_eq!(records[0].id, id);
        assert_eq!(records[0].provider, "huggingface");
        assert_eq!(records[0].display_name, "Private models");
        let debug = format!("{records:?}");
        assert!(!debug.contains("hf_secret_must_never_be_listed"));
        assert!(!debug.contains("secret_reference"));
    }

    #[test]
    fn database_cannot_redirect_a_credential_reference() {
        let directory = tempfile::tempdir().unwrap();
        let mut connection = Connection::open_in_memory().unwrap();
        crate::migration::migrate(&mut connection).unwrap();
        let actor = Uuid::new_v4();
        crate::store::insert_device(
            &connection,
            &actor,
            "test",
            "macos",
            b"spki",
            &format!("fp-{actor}"),
            "owner",
        )
        .unwrap();
        let store = CredentialStore::new(directory.path());
        let id = store
            .store(&connection, "huggingface", "test", "secret", actor)
            .unwrap();
        connection
            .execute(
                "UPDATE provider_credentials SET secret_reference = '/etc/passwd' WHERE id = ?1",
                [id.to_string()],
            )
            .unwrap();

        assert!(store.resolve(&connection, id).is_err());
    }
}
