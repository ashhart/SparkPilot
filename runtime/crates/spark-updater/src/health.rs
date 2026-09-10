//! Run all five local health checks in order; unavailable checks are Skipped with reasons and never count as passes.

use std::path::{Path, PathBuf};

use serde::Serialize;
use spark_core::identity::FileIdentityStore;

/// Result of one check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HealthStatus {
    Passed,
    Failed,
    Skipped,
}

/// One named check and what it found.
#[derive(Debug, Clone, Serialize)]
pub struct HealthCheck {
    pub name: &'static str,
    pub status: HealthStatus,
    pub detail: String,
}

impl HealthCheck {
    fn passed(name: &'static str, detail: impl Into<String>) -> Self {
        Self {
            name,
            status: HealthStatus::Passed,
            detail: detail.into(),
        }
    }

    fn failed(name: &'static str, detail: impl Into<String>) -> Self {
        Self {
            name,
            status: HealthStatus::Failed,
            detail: detail.into(),
        }
    }

    fn skipped(name: &'static str, detail: impl Into<String>) -> Self {
        Self {
            name,
            status: HealthStatus::Skipped,
            detail: detail.into(),
        }
    }
}

/// The whole gate.
#[derive(Debug, Clone, Serialize)]
pub struct HealthReport {
    pub healthy: bool,
    pub data_dir: PathBuf,
    pub checks: Vec<HealthCheck>,
}

/// Optionally require the helper while units start; an absent optional socket is reported Skipped rather than passed.
pub fn run_health_gate(
    data_dir: &Path,
    privileged_socket: &Path,
    require_privileged_helper: bool,
) -> HealthReport {
    run_health_gate_with_credentials(data_dir, privileged_socket, require_privileged_helper, None)
}

pub fn run_health_gate_with_credentials(
    data_dir: &Path,
    privileged_socket: &Path,
    require_privileged_helper: bool,
    credentials: Option<&Path>,
) -> HealthReport {
    let mut checks = Vec::new();

    checks.push(match credentials {
        Some(directory) => match spark_core::identity::credentials::load_credentials(directory) {
            Ok(identity) => HealthCheck::passed(
                "identity",
                format!("node {} is loadable from credentials", identity.node_id()),
            ),
            Err(error) => HealthCheck::failed("identity", error.to_string()),
        },
        None => check_identity(data_dir),
    });
    let (database_check, schema_ok) = check_database(data_dir);
    checks.push(database_check);
    checks.push(check_privileged_helper(
        privileged_socket,
        require_privileged_helper,
    ));
    checks.push(match credentials {
        Some(directory) => match sparkd::tls::load_credentials(directory) {
            Ok(_) => HealthCheck::passed("discovery", "node TLS credentials are loadable"),
            Err(error) => HealthCheck::failed("discovery", error.to_string()),
        },
        None => check_discovery_configuration(data_dir),
    });
    checks.push(if schema_ok {
        check_model_inventory(data_dir)
    } else {
        HealthCheck::skipped("model_inventory", "database is not usable")
    });

    let healthy = checks
        .iter()
        .all(|check| check.status == HealthStatus::Passed);

    HealthReport {
        healthy,
        data_dir: data_dir.to_path_buf(),
        checks,
    }
}

fn check_identity(data_dir: &Path) -> HealthCheck {
    match FileIdentityStore::new(data_dir.join("identity")).load() {
        Ok(Some(identity)) => HealthCheck::passed(
            "identity",
            format!("node {} is loadable", identity.node_id()),
        ),
        Ok(None) => HealthCheck::failed("identity", "no node identity exists"),
        Err(error) => HealthCheck::failed("identity", error.to_string()),
    }
}

fn check_database(data_dir: &Path) -> (HealthCheck, bool) {
    let path = data_dir.join("runtime.db");
    if !path.exists() {
        return (
            HealthCheck::failed("database", format!("{} does not exist", path.display())),
            false,
        );
    }
    let conn = match sparkd::migration::open(&path) {
        Ok(conn) => conn,
        Err(error) => return (HealthCheck::failed("database", error.to_string()), false),
    };
    let applied: Result<i64, _> = conn.query_row(
        "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
        [],
        |row| row.get(0),
    );
    let expected = sparkd::migration::MIGRATIONS
        .iter()
        .filter_map(|migration| migration.version.parse::<i64>().ok())
        .max()
        .unwrap_or(0);
    match applied {
        Ok(version) if version == expected => (
            HealthCheck::passed("database", format!("schema version {version}")),
            true,
        ),
        Ok(version) => (
            HealthCheck::failed(
                "database",
                format!("schema version {version}; this build expects {expected}"),
            ),
            false,
        ),
        Err(error) => (HealthCheck::failed("database", error.to_string()), false),
    }
}

fn check_privileged_helper(socket: &Path, required: bool) -> HealthCheck {
    if !socket.exists() {
        return if required {
            HealthCheck::failed(
                "privileged_helper",
                format!("no socket at {}", socket.display()),
            )
        } else {
            HealthCheck::skipped(
                "privileged_helper",
                format!("no socket at {} yet", socket.display()),
            )
        };
    }
    let client = sparkd::privd::PrivilegedClient::new(socket);
    let request_id = uuid::Uuid::new_v4();
    match client
        .call(spark_privd::protocol::PrivilegedOperation::ProbeContainerRuntime { request_id })
    {
        Ok(response) if response.accepted => {
            HealthCheck::passed("privileged_helper", response.message)
        }
        Ok(response) => HealthCheck::failed(
            "privileged_helper",
            format!("{}: {}", response.code, response.message),
        ),
        Err(error) => HealthCheck::failed("privileged_helper", error.to_string()),
    }
}

/// Check discovery's required certificate without publishing a competing Bonjour registration; this does not probe live discovery.
fn check_discovery_configuration(data_dir: &Path) -> HealthCheck {
    let certificate = data_dir.join("identity").join("node.crt");
    if certificate.exists() {
        HealthCheck::passed(
            "discovery",
            format!("node certificate present at {}", certificate.display()),
        )
    } else {
        HealthCheck::skipped(
            "discovery",
            format!(
                "no node certificate at {} yet; sparkd creates it on first start",
                certificate.display()
            ),
        )
    }
}

fn check_model_inventory(data_dir: &Path) -> HealthCheck {
    let path = data_dir.join("runtime.db");
    let conn = match sparkd::migration::open(&path) {
        Ok(conn) => conn,
        Err(error) => return HealthCheck::failed("model_inventory", error.to_string()),
    };
    let count: Result<i64, _> = conn.query_row("SELECT COUNT(*) FROM models", [], |row| row.get(0));
    match count {
        Ok(count) => HealthCheck::passed("model_inventory", format!("{count} catalogue rows")),
        Err(error) => HealthCheck::failed("model_inventory", error.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(report: &HealthReport, name: &str) -> HealthStatus {
        report
            .checks
            .iter()
            .find(|check| check.name == name)
            .unwrap()
            .status
    }

    #[test]
    fn protected_node_health_uses_delivered_credentials_after_legacy_cleanup() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        spark_installer::prepare(dir.path(), "Protected Spark", false).unwrap();
        let legacy = dir.path().join("identity");
        sparkd::tls::load_or_create(&legacy).unwrap();
        let credentials = dir.path().join("credentials");
        std::fs::create_dir(&credentials).unwrap();
        for name in ["identity.key", "identity.json", "node.key", "node.crt"] {
            std::fs::copy(legacy.join(name), credentials.join(name)).unwrap();
            std::fs::set_permissions(
                credentials.join(name),
                std::fs::Permissions::from_mode(0o440),
            )
            .unwrap();
        }
        std::fs::set_permissions(&credentials, std::fs::Permissions::from_mode(0o550)).unwrap();
        std::fs::remove_file(legacy.join("identity.key")).unwrap();
        std::fs::remove_file(legacy.join("node.key")).unwrap();
        let report = run_health_gate_with_credentials(
            dir.path(),
            &dir.path().join("absent.sock"),
            false,
            Some(&credentials),
        );
        std::fs::set_permissions(&credentials, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(
            status(&report, "identity"),
            HealthStatus::Passed,
            "{report:?}"
        );
        assert_eq!(status(&report, "discovery"), HealthStatus::Passed);
        assert!(!legacy.join("identity.key").exists());
        assert!(!legacy.join("node.key").exists());
        let missing = run_health_gate_with_credentials(
            dir.path(),
            &dir.path().join("absent.sock"),
            false,
            Some(&dir.path().join("missing")),
        );
        assert_eq!(status(&missing, "identity"), HealthStatus::Failed);
        assert_eq!(status(&missing, "discovery"), HealthStatus::Failed);
    }

    #[test]
    fn an_unprepared_node_fails_the_gate() {
        let dir = tempfile::tempdir().unwrap();
        let report = run_health_gate(dir.path(), &dir.path().join("privd.sock"), false);
        assert!(!report.healthy);
        assert_eq!(status(&report, "identity"), HealthStatus::Failed);
        assert_eq!(status(&report, "database"), HealthStatus::Failed);
        assert_eq!(status(&report, "model_inventory"), HealthStatus::Skipped);
    }

    #[test]
    fn a_prepared_node_passes_everything_it_can_prove() {
        let dir = tempfile::tempdir().unwrap();
        spark_installer::prepare(dir.path(), "Test Spark", false).unwrap();
        std::fs::write(dir.path().join("identity").join("node.crt"), b"-----BEGIN").unwrap();

        let report = run_health_gate(dir.path(), &dir.path().join("privd.sock"), false);
        assert_eq!(status(&report, "identity"), HealthStatus::Passed);
        assert_eq!(status(&report, "database"), HealthStatus::Passed);
        assert_eq!(status(&report, "discovery"), HealthStatus::Passed);
        assert_eq!(status(&report, "model_inventory"), HealthStatus::Passed);
        // An absent helper is skipped and prevents the overall report from claiming healthy.
        assert_eq!(status(&report, "privileged_helper"), HealthStatus::Skipped);
        assert!(!report.healthy);
    }

    #[test]
    fn a_missing_helper_is_a_failure_when_it_is_required() {
        let dir = tempfile::tempdir().unwrap();
        spark_installer::prepare(dir.path(), "Test Spark", false).unwrap();
        let report = run_health_gate(dir.path(), &dir.path().join("privd.sock"), true);
        assert_eq!(status(&report, "privileged_helper"), HealthStatus::Failed);
        assert!(!report.healthy);
    }

    #[test]
    fn a_newer_schema_than_this_build_fails_the_database_check() {
        let dir = tempfile::tempdir().unwrap();
        spark_installer::prepare(dir.path(), "Test Spark", false).unwrap();
        let conn = sparkd::migration::open(&dir.path().join("runtime.db")).unwrap();
        conn.execute(
            "INSERT INTO schema_migrations (version, applied_at) \
             VALUES (9999, '2026-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        drop(conn);

        let report = run_health_gate(dir.path(), &dir.path().join("privd.sock"), false);
        assert_eq!(status(&report, "database"), HealthStatus::Failed);
        assert_eq!(status(&report, "model_inventory"), HealthStatus::Skipped);
        assert!(!report.healthy);
    }
}
