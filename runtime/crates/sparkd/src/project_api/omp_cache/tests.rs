use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

fn fixture() -> (Release, Vec<u8>) {
    let bytes = b"fixture omp binary".to_vec();
    (
        Release {
            version: "18.1.12".into(),
            url: "unused".into(),
            digest: Sha256::digest(&bytes).to_vec(),
        },
        bytes,
    )
}

#[test]
fn the_pin_matches_the_launcher_and_names_a_github_release() {
    let release = Release::pinned().unwrap();
    assert_eq!(release.version, "18.1.12");
    assert!(
        release.url.starts_with(
            "https://github.com/can1357/oh-my-pi/releases/download/v18.1.12/omp-linux-"
        )
    );
    assert_eq!(release.digest.len(), 32);
    assert_eq!(release.workspace_path(), ".spark-home/tools/omp-18.1.12");
}

#[test]
fn the_host_downloads_once_and_every_workspace_is_seeded_from_the_cache() {
    let data = tempfile::tempdir().unwrap();
    let first = tempfile::tempdir().unwrap();
    let second = tempfile::tempdir().unwrap();
    let (release, bytes) = fixture();
    let downloads = AtomicUsize::new(0);
    let fetch = || {
        downloads.fetch_add(1, Ordering::SeqCst);
        Ok(bytes.clone())
    };
    assert!(!seed_with(data.path(), first.path(), &release).unwrap());
    assert!(warm_with(data.path(), &release, fetch).unwrap());
    assert!(!warm_with(data.path(), &release, fetch).unwrap());
    assert_eq!(downloads.load(Ordering::SeqCst), 1);
    assert!(seed_with(data.path(), first.path(), &release).unwrap());
    assert!(seed_with(data.path(), second.path(), &release).unwrap());
    let seeded = first.path().join(".spark-home/tools/omp-18.1.12");
    assert_eq!(std::fs::read(&seeded).unwrap(), bytes);
    use std::os::unix::fs::PermissionsExt as _;
    assert_eq!(
        std::fs::metadata(&seeded).unwrap().permissions().mode() & 0o777,
        0o700
    );
    // A workspace that altered its copy gets the verified bytes back; the cache never learns the change.
    std::fs::write(&seeded, "workspace modified").unwrap();
    assert!(seed_with(data.path(), first.path(), &release).unwrap());
    assert_eq!(std::fs::read(&seeded).unwrap(), bytes);
    assert_eq!(
        std::fs::read(second.path().join(".spark-home/tools/omp-18.1.12")).unwrap(),
        bytes
    );
}

#[test]
fn a_download_that_does_not_match_the_pin_is_refused_and_not_cached() {
    let data = tempfile::tempdir().unwrap();
    let (release, _) = fixture();
    let error = warm_with(data.path(), &release, || Ok(b"tampered".to_vec()))
        .unwrap_err()
        .to_string();
    assert!(error.contains("verification failed"), "{error}");
    assert!(cached(data.path(), &release).is_none());
}
