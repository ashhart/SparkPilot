//! Prepare identity/schema and mint the single-use first-owner invitation through the administrator-authenticated install channel.

use std::path::{Path, PathBuf};

use serde::Serialize;
use spark_core::identity::{FileIdentityStore, IdentityStore, NodeIdentity};
use thiserror::Error;

/// DER prefix of an Ed25519 `SubjectPublicKeyInfo` (RFC 8410 §4).
const ED25519_SPKI_PREFIX: [u8; 12] = [
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
];

/// Display name of the install-time administrator grant.
pub const INSTALLER_DEVICE_NAME: &str = "Spark Installer";

/// Default first-owner invitation lifetime (§15.3: five minutes).
pub const OWNER_INVITATION_SECONDS: i64 = 300;
/// An owner invitation is claimed at the console; a day is already generous, and a non-positive lifetime is nonsense.
pub const MAX_OWNER_INVITATION_SECONDS: i64 = 24 * 60 * 60;

#[derive(Debug, Error)]
pub enum BootstrapError {
    #[error("identity error: {0}")]
    Identity(String),
    #[error("database error: {0}")]
    Database(String),
    #[error(
        "database schema {found} is newer than this build understands ({known}); \
         install the matching release or use an explicit rollback package"
    )]
    SchemaDowngrade { found: u64, known: u64 },
    #[error("this node already has an owner; pair an additional device with an invitation")]
    OwnerAlreadyExists,
    #[error("pairing error: {0}")]
    Pairing(String),
    #[error(
        "this node has no TLS certificate yet ({0}); start sparkd before minting an owner \
         invitation, so the app is given a pin instead of pairing unpinned"
    )]
    NoTlsIdentity(String),
    #[error("serialisation error: {0}")]
    Json(String),
    #[error(
        "invitation lifetime {0} seconds is outside 1..={MAX_OWNER_INVITATION_SECONDS}; \
         refusing to mint an owner grant that never expires or is already expired"
    )]
    InvalidExpiry(i64),
}

fn validate_expiry(expires_in_seconds: i64) -> Result<(), BootstrapError> {
    if (1..=MAX_OWNER_INVITATION_SECONDS).contains(&expires_in_seconds) {
        Ok(())
    } else {
        Err(BootstrapError::InvalidExpiry(expires_in_seconds))
    }
}

/// What [`prepare`] did.
#[derive(Debug, Clone, Serialize)]
pub struct PrepareReport {
    pub node_id: String,
    pub node_name: String,
    pub authority_fingerprint: String,
    /// True when this call created the identity rather than loading it.
    pub identity_created: bool,
    pub migrations_applied: Vec<String>,
    pub schema_version: u64,
    pub data_dir: PathBuf,
}

/// Return authority key, matching SHA-256 fingerprint and separate TLS leaf pin over authenticated SSH; see RUNTIME-INVARIANTS.md.
#[derive(Debug, Clone, Serialize)]
pub struct BootstrapReport {
    pub node_id: String,
    pub node_name: String,
    pub authority_fingerprint: String,
    /// Hex-encoded Ed25519 owner-authority public key (32 bytes).
    pub authority_public_key: String,
    /// Lowercase hex SHA-256 of the local API leaf certificate, in DER form.
    pub tls_fingerprint: String,
    pub expires_at: String,
    /// The signed invitation payload, exactly as the pairing API expects it.
    pub invitation: serde_json::Value,
}

/// What the database holds versus what this build knows.
#[derive(Debug, Clone, Copy, Serialize)]
pub struct SchemaReport {
    /// Highest migration recorded in the database (0 when there is none).
    pub applied: u64,
    /// Highest migration this build ships.
    pub known: u64,
    /// True when the database is ahead of this build.
    pub downgrade: bool,
}

/// Read schema compatibility with the outgoing binary in preinst so incompatible downgrades fail before package files change.
pub fn schema_report(data_dir: &Path) -> Result<SchemaReport, BootstrapError> {
    let known = highest_known_schema_version();
    let db_path = data_dir.join("runtime.db");
    if !db_path.exists() {
        return Ok(SchemaReport {
            applied: 0,
            known,
            downgrade: false,
        });
    }
    let conn =
        sparkd::migration::open(&db_path).map_err(|e| BootstrapError::Database(e.to_string()))?;
    let applied = applied_schema_version(&conn)?;
    Ok(SchemaReport {
        applied,
        known,
        downgrade: applied > known,
    })
}

/// Create missing identity and migrate once; repeated preparation reuses identity and skips applied migrations.
pub fn prepare(
    data_dir: &Path,
    node_name: &str,
    allow_downgrade: bool,
) -> Result<PrepareReport, BootstrapError> {
    let identity_dir = data_dir.join("identity");
    let identity_existed = identity_dir
        .join(spark_core::identity::KEY_FILE_NAME)
        .exists();
    let identity = FileIdentityStore::new(&identity_dir)
        .load_or_create(node_name)
        .map_err(|error| BootstrapError::Identity(error.to_string()))?;

    prepare_with_identity(data_dir, identity, !identity_existed, allow_downgrade)
}

pub fn prepare_with_identity(
    data_dir: &Path,
    identity: NodeIdentity,
    identity_created: bool,
    allow_downgrade: bool,
) -> Result<PrepareReport, BootstrapError> {
    let db_path = data_dir.join("runtime.db");
    let mut conn =
        sparkd::migration::open(&db_path).map_err(|e| BootstrapError::Database(e.to_string()))?;

    let known = highest_known_schema_version();
    let found = applied_schema_version(&conn)?;
    if found > known && !allow_downgrade {
        return Err(BootstrapError::SchemaDowngrade { found, known });
    }

    let migrations_applied = sparkd::migration::migrate_with_recovery_point(&mut conn, &db_path)
        .map_err(|e| BootstrapError::Database(e.to_string()))?
        .applied;

    Ok(PrepareReport {
        node_id: identity.node_id().to_string(),
        node_name: identity.public.node_name.clone(),
        authority_fingerprint: identity.fingerprint().to_owned(),
        identity_created,
        migrations_applied,
        schema_version: applied_schema_version(&conn)?,
        data_dir: data_dir.to_path_buf(),
    })
}

/// Mint one first-owner grant; an existing paired owner makes installer replay fail with OwnerAlreadyExists.
pub fn bootstrap_owner(
    data_dir: &Path,
    expires_in_seconds: i64,
) -> Result<BootstrapReport, BootstrapError> {
    validate_expiry(expires_in_seconds)?;
    let identity = FileIdentityStore::new(data_dir.join("identity"))
        .load()
        .map_err(|error| BootstrapError::Identity(error.to_string()))?
        .ok_or_else(|| {
            BootstrapError::Identity("no node identity; run `spark-installer prepare` first".into())
        })?;

    // Refuse to mint an invitation the app could only claim unpinned.
    let certificate_path = data_dir
        .join("identity")
        .join(sparkd::tls::CERTIFICATE_FILE_NAME);
    let tls_fingerprint = sparkd::tls::fingerprint_at(&certificate_path)
        .map_err(|error| BootstrapError::NoTlsIdentity(error.to_string()))?;

    bootstrap_owner_with_identity(data_dir, expires_in_seconds, identity, tls_fingerprint)
}

pub fn bootstrap_owner_with_identity(
    data_dir: &Path,
    expires_in_seconds: i64,
    identity: NodeIdentity,
    tls_fingerprint: String,
) -> Result<BootstrapReport, BootstrapError> {
    validate_expiry(expires_in_seconds)?;
    let db_path = data_dir.join("runtime.db");
    let conn =
        sparkd::migration::open(&db_path).map_err(|e| BootstrapError::Database(e.to_string()))?;

    if sparkd::store::has_owner(&conn).map_err(|e| BootstrapError::Database(e.to_string()))? {
        return Err(BootstrapError::OwnerAlreadyExists);
    }

    let issuer = installer_device(&conn, &identity)?;
    let issued = sparkd::pairing::issue_invitation(
        &conn,
        &identity,
        &issuer,
        "owner".to_owned(),
        Some(expires_in_seconds),
        Some("First owner".to_owned()),
    )
    .map_err(|error| BootstrapError::Pairing(error.to_string()))?;

    let invitation = serde_json::to_value(&issued.payload)
        .map_err(|error| BootstrapError::Json(error.to_string()))?;

    Ok(BootstrapReport {
        node_id: identity.node_id().to_string(),
        node_name: identity.public.node_name.clone(),
        authority_fingerprint: identity.fingerprint().to_owned(),
        authority_public_key: identity.public.authority_public_key.clone(),
        tls_fingerprint,
        expires_at: issued.expires_at,
        invitation,
    })
}

/// Record an auditable Ed25519 installer issuer that cannot authenticate as a P-256 device; see RUNTIME-INVARIANTS.md.
fn installer_device(
    conn: &rusqlite::Connection,
    identity: &NodeIdentity,
) -> Result<uuid::Uuid, BootstrapError> {
    let spki = ed25519_spki(identity)?;
    let fingerprint = sparkd::crypto::sha256_hex(&spki);

    if let Some(existing) = existing_device_id(conn, &fingerprint)? {
        return Ok(existing);
    }

    let id = uuid::Uuid::new_v4();
    sparkd::store::insert_installer_device(conn, &id, &spki)
        .map_err(|error| BootstrapError::Database(error.to_string()))?;
    Ok(id)
}

fn existing_device_id(
    conn: &rusqlite::Connection,
    fingerprint: &str,
) -> Result<Option<uuid::Uuid>, BootstrapError> {
    let mut statement = conn
        .prepare("SELECT id FROM devices WHERE public_key_fingerprint = ?1")
        .map_err(|error| BootstrapError::Database(error.to_string()))?;
    let mut rows = statement
        .query([fingerprint])
        .map_err(|error| BootstrapError::Database(error.to_string()))?;
    let Some(row) = rows
        .next()
        .map_err(|error| BootstrapError::Database(error.to_string()))?
    else {
        return Ok(None);
    };
    let raw: String = row
        .get(0)
        .map_err(|error| BootstrapError::Database(error.to_string()))?;
    uuid::Uuid::parse_str(&raw)
        .map(Some)
        .map_err(|error| BootstrapError::Database(error.to_string()))
}

fn ed25519_spki(identity: &NodeIdentity) -> Result<Vec<u8>, BootstrapError> {
    let raw = hex::decode(&identity.public.authority_public_key)
        .map_err(|error| BootstrapError::Identity(error.to_string()))?;
    if raw.len() != 32 {
        return Err(BootstrapError::Identity(
            "authority public key is not 32 bytes".into(),
        ));
    }
    let mut spki = Vec::with_capacity(ED25519_SPKI_PREFIX.len() + raw.len());
    spki.extend_from_slice(&ED25519_SPKI_PREFIX);
    spki.extend_from_slice(&raw);
    Ok(spki)
}

fn highest_known_schema_version() -> u64 {
    sparkd::migration::MIGRATIONS
        .iter()
        .filter_map(|migration| migration.version.parse::<u64>().ok())
        .max()
        .unwrap_or(0)
}

fn applied_schema_version(conn: &rusqlite::Connection) -> Result<u64, BootstrapError> {
    let exists: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master \
             WHERE type = 'table' AND name = 'schema_migrations'",
            [],
            |row| row.get(0),
        )
        .map_err(|error| BootstrapError::Database(error.to_string()))?;
    if exists == 0 {
        return Ok(0);
    }
    let version: i64 = conn
        .query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            [],
            |row| row.get(0),
        )
        .map_err(|error| BootstrapError::Database(error.to_string()))?;
    Ok(version.max(0) as u64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::pkcs8::DecodePublicKey;
    use sha2::{Digest, Sha256};

    /// A prepared node with the certificate `sparkd` would have created.
    fn prepared_node(dir: &Path) {
        prepare(dir, "Test Spark", false).unwrap();
        sparkd::tls::load_or_create(&dir.join("identity")).unwrap();
    }

    #[test]
    fn prepare_is_idempotent_and_creates_identity_once() {
        let dir = tempfile::tempdir().unwrap();
        let first = prepare(dir.path(), "Test Spark", false).unwrap();
        assert!(first.identity_created);
        assert!(!first.migrations_applied.is_empty());
        assert_eq!(first.schema_version, highest_known_schema_version());

        let second = prepare(dir.path(), "Different Name", false).unwrap();
        assert!(!second.identity_created);
        assert!(second.migrations_applied.is_empty());
        // The stored identity wins; a re-run never renames or re-keys a node.
        assert_eq!(second.node_id, first.node_id);
        assert_eq!(second.node_name, "Test Spark");
    }

    #[test]
    fn schema_report_describes_a_fresh_and_a_prepared_node() {
        let dir = tempfile::tempdir().unwrap();
        let fresh = schema_report(dir.path()).unwrap();
        assert_eq!(fresh.applied, 0);
        assert!(!fresh.downgrade);

        prepare(dir.path(), "Test Spark", false).unwrap();
        let prepared = schema_report(dir.path()).unwrap();
        assert_eq!(prepared.applied, prepared.known);
        assert!(!prepared.downgrade);
    }

    #[test]
    fn schema_report_flags_a_database_from_a_newer_release() {
        let dir = tempfile::tempdir().unwrap();
        prepare(dir.path(), "Test Spark", false).unwrap();
        let conn = sparkd::migration::open(&dir.path().join("runtime.db")).unwrap();
        conn.execute(
            "INSERT INTO schema_migrations (version, applied_at) \
             VALUES (?1, '2026-01-01T00:00:00Z')",
            [(highest_known_schema_version() + 1) as i64],
        )
        .unwrap();
        drop(conn);

        let report = schema_report(dir.path()).unwrap();
        assert!(report.downgrade);
        assert_eq!(report.applied, report.known + 1);
    }

    #[test]
    fn prepare_refuses_a_schema_downgrade() {
        let dir = tempfile::tempdir().unwrap();
        prepare(dir.path(), "Test Spark", false).unwrap();

        let conn = sparkd::migration::open(&dir.path().join("runtime.db")).unwrap();
        conn.execute(
            "INSERT INTO schema_migrations (version, applied_at) VALUES (?1, '2026-01-01T00:00:00Z')",
            [(highest_known_schema_version() + 1) as i64],
        )
        .unwrap();
        drop(conn);

        assert!(matches!(
            prepare(dir.path(), "Test Spark", false),
            Err(BootstrapError::SchemaDowngrade { .. })
        ));
        // An explicit package rollback still needs a compatible database recovery point.
        assert!(
            matches!(prepare(dir.path(), "Test Spark", true), Err(BootstrapError::Database(message)) if message.contains("does not recognise"))
        );
        assert_eq!(
            schema_report(dir.path()).unwrap().applied,
            highest_known_schema_version() + 1
        );
    }

    #[test]
    fn bootstrap_owner_issues_a_verifiable_single_use_invitation() {
        let dir = tempfile::tempdir().unwrap();
        prepared_node(dir.path());

        let report = bootstrap_owner(dir.path(), OWNER_INVITATION_SECONDS).unwrap();
        assert_eq!(report.invitation["role"], "owner");
        assert_eq!(report.invitation["node_id"], report.node_id);
        assert_eq!(
            report.invitation["authority_fingerprint"],
            report.authority_fingerprint
        );
        assert!(report.invitation["signature"].is_string());

        // The invitation verifies against the node's own authority key.
        let identity = FileIdentityStore::new(dir.path().join("identity"))
            .load()
            .unwrap()
            .unwrap();
        let payload: sparkd::pairing::InvitationPayload =
            serde_json::from_value(report.invitation.clone()).unwrap();
        payload.verify(&identity).unwrap();
    }

    /// The lifetime is checked before any identity or database is touched, so a bad flag cannot mint anything.
    #[test]
    fn an_owner_invitation_lifetime_outside_the_bound_is_refused_first() {
        let dir = tempfile::tempdir().unwrap();
        for seconds in [0, -1, MAX_OWNER_INVITATION_SECONDS + 1, i64::MAX, i64::MIN] {
            assert!(
                matches!(
                    bootstrap_owner(dir.path(), seconds),
                    Err(BootstrapError::InvalidExpiry(found)) if found == seconds
                ),
                "{seconds} was not refused"
            );
        }
        assert!(!dir.path().join("runtime.db").exists());

        prepared_node(dir.path());
        let report = bootstrap_owner(dir.path(), MAX_OWNER_INVITATION_SECONDS).unwrap();
        assert_eq!(report.invitation["role"], "owner");
    }

    #[test]
    fn bootstrap_owner_reuses_one_installer_grant() {
        let dir = tempfile::tempdir().unwrap();
        prepared_node(dir.path());
        bootstrap_owner(dir.path(), OWNER_INVITATION_SECONDS).unwrap();
        bootstrap_owner(dir.path(), OWNER_INVITATION_SECONDS).unwrap();

        let conn = sparkd::migration::open(&dir.path().join("runtime.db")).unwrap();
        let installers: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM devices WHERE display_name = ?1",
                [INSTALLER_DEVICE_NAME],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(installers, 1);
    }

    #[test]
    fn bootstrap_owner_refuses_once_an_owner_exists() {
        let dir = tempfile::tempdir().unwrap();
        prepared_node(dir.path());

        let conn = sparkd::migration::open(&dir.path().join("runtime.db")).unwrap();
        sparkd::store::insert_device(
            &conn,
            &uuid::Uuid::new_v4(),
            "Owner iPhone",
            "ios",
            b"spki",
            "fingerprint",
            "owner",
        )
        .unwrap();
        drop(conn);

        assert!(matches!(
            bootstrap_owner(dir.path(), OWNER_INVITATION_SECONDS),
            Err(BootstrapError::OwnerAlreadyExists)
        ));
    }

    #[test]
    fn the_report_carries_verifiable_trust_material() {
        let dir = tempfile::tempdir().unwrap();
        prepared_node(dir.path());
        let report = bootstrap_owner(dir.path(), OWNER_INVITATION_SECONDS).unwrap();

        // Verify the returned authority key hashes to the fingerprint carried by the authenticated channel.
        let key = hex::decode(&report.authority_public_key).unwrap();
        assert_eq!(key.len(), 32);
        assert_eq!(
            hex::encode(Sha256::digest(&key)),
            report.authority_fingerprint
        );

        // The TLS pin is a different value from a different key.
        assert_eq!(report.tls_fingerprint.len(), 64);
        assert_ne!(report.tls_fingerprint, report.authority_fingerprint);
        assert_eq!(
            report.tls_fingerprint,
            sparkd::tls::fingerprint_at(
                &dir.path()
                    .join("identity")
                    .join(sparkd::tls::CERTIFICATE_FILE_NAME)
            )
            .unwrap()
        );
    }

    #[test]
    fn a_substituted_authority_key_no_longer_matches_the_fingerprint() {
        let dir = tempfile::tempdir().unwrap();
        prepared_node(dir.path());
        let report = bootstrap_owner(dir.path(), OWNER_INVITATION_SECONDS).unwrap();

        // A substituted key must fail against the authority fingerprint received over authenticated SSH.
        let attacker = ed25519_dalek::SigningKey::from_bytes(&[42u8; 32]);
        let substituted = hex::encode(attacker.verifying_key().to_bytes());
        assert_ne!(substituted, report.authority_public_key);
        assert_ne!(
            hex::encode(Sha256::digest(hex::decode(&substituted).unwrap())),
            report.authority_fingerprint
        );
    }

    #[test]
    fn bootstrap_owner_refuses_without_a_tls_identity_to_pin() {
        let dir = tempfile::tempdir().unwrap();
        prepare(dir.path(), "Test Spark", false).unwrap();
        assert!(matches!(
            bootstrap_owner(dir.path(), OWNER_INVITATION_SECONDS),
            Err(BootstrapError::NoTlsIdentity(_))
        ));
    }

    #[test]
    fn bootstrap_owner_needs_a_prepared_node() {
        let dir = tempfile::tempdir().unwrap();
        assert!(matches!(
            bootstrap_owner(dir.path(), OWNER_INVITATION_SECONDS),
            Err(BootstrapError::Identity(_))
        ));
    }

    #[test]
    fn the_installer_grant_can_never_sign_a_device_request() {
        // The Ed25519 provenance key must not parse as a P-256 device signing key.
        let dir = tempfile::tempdir().unwrap();
        prepared_node(dir.path());
        let identity = FileIdentityStore::new(dir.path().join("identity"))
            .load()
            .unwrap()
            .unwrap();
        let spki = ed25519_spki(&identity).unwrap();
        assert_eq!(spki.len(), 44);
        assert!(p256::PublicKey::from_public_key_der(&spki).is_err());
    }
}
