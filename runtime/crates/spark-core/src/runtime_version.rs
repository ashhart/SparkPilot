//! Report the package revision installed by dpkg without invoking a subprocess on observation requests.

use std::io::Read;
use std::path::Path;

const PACKAGE_VERSION_PATH: &str = "/usr/share/spark-runtime/package-version";

/// Read once at daemon startup; source builds and older packages retain the source version.
pub fn installed_runtime_version() -> String {
    if std::env::current_exe().ok().as_deref() != Some(Path::new("/usr/lib/spark-runtime/sparkd")) {
        return crate::RUNTIME_VERSION.to_owned();
    }
    version_from_file(Path::new(PACKAGE_VERSION_PATH), crate::RUNTIME_VERSION)
}

fn version_from_file(path: &Path, source_version: &str) -> String {
    let mut value = String::new();
    let loaded = std::fs::File::open(path)
        .and_then(|file| file.take(129).read_to_string(&mut value))
        .is_ok();
    let version = value.trim();
    let revision = version
        .strip_prefix(source_version)
        .and_then(|rest| rest.strip_prefix('-'));
    if loaded
        && value.len() <= 128
        && revision.is_some_and(|revision| {
            !revision.is_empty()
                && revision
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
        })
    {
        version.to_owned()
    } else {
        source_version.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installed_revision_survives_identity_reporting_and_replacement() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("package-version");
        for revision in [2, 3, 10] {
            let version = format!("0.1.13-0qa20260907.{revision}");
            std::fs::write(&path, format!("{version}\n")).unwrap();
            assert_eq!(version_from_file(&path, "0.1.13"), version);
        }
    }

    #[test]
    fn missing_invalid_or_foreign_package_metadata_cannot_misidentify_this_binary() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("package-version");
        assert_eq!(version_from_file(&path, "0.1.13"), "0.1.13");
        for value in ["0.1.14-1", "0.1.13-", "0.1.13-1\nextra", "0.1.13-1/2"] {
            std::fs::write(&path, value).unwrap();
            assert_eq!(version_from_file(&path, "0.1.13"), "0.1.13");
        }
        std::fs::write(&path, format!("0.1.13-{}", "1".repeat(129))).unwrap();
        assert_eq!(version_from_file(&path, "0.1.13"), "0.1.13");
    }
}
