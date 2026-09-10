use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

fn fixture() -> (Package, Vec<u8>) {
    let mut tar = tar::Builder::new(Vec::new());
    for name in [
        "bin/codex",
        "bin/codex-code-mode-host",
        "codex-path/rg",
        "codex-resources/bwrap",
        "codex-resources/zsh/bin/zsh",
        "codex-package.json",
    ] {
        let bytes = format!("fixture-{name}");
        let mut header = tar::Header::new_gnu();
        header.set_size(bytes.len() as u64);
        header.set_mode(0o755);
        header.set_cksum();
        tar.append_data(
            &mut header,
            format!("package/vendor/test/{name}"),
            bytes.as_bytes(),
        )
        .unwrap();
    }
    let tar = tar.into_inner().unwrap();
    let mut gzip = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    std::io::Write::write_all(&mut gzip, &tar).unwrap();
    let bytes = gzip.finish().unwrap();
    (
        Package {
            url: "unused".into(),
            integrity: Sha512::digest(&bytes).to_vec(),
            triple: "test",
        },
        bytes,
    )
}

#[test]
fn separate_projects_download_once_and_never_share_writable_tools() {
    let temp = tempfile::tempdir().unwrap();
    let first = tempfile::tempdir().unwrap();
    let second = tempfile::tempdir().unwrap();
    let (package, bytes) = fixture();
    let downloads = AtomicUsize::new(0);
    let fetch = || {
        downloads.fetch_add(1, Ordering::SeqCst);
        Ok(bytes.clone())
    };
    let directory = prepare_with(temp.path(), first.path(), &package, fetch).unwrap();
    std::fs::write(
        first.path().join(&directory).join("bin/codex"),
        "project modified",
    )
    .unwrap();
    prepare_with(temp.path(), second.path(), &package, fetch).unwrap();
    assert_eq!(downloads.load(Ordering::SeqCst), 1);
    assert_eq!(
        std::fs::read(second.path().join(&directory).join("bin/codex")).unwrap(),
        b"fixture-bin/codex"
    );
    assert_eq!(
        std::fs::read(second.path().join(&directory).join("codex-path/rg")).unwrap(),
        b"fixture-codex-path/rg"
    );
    prepare_with(temp.path(), first.path(), &package, fetch).unwrap();
    assert_eq!(downloads.load(Ordering::SeqCst), 1);
    assert_eq!(
        std::fs::read(first.path().join(&directory).join("bin/codex")).unwrap(),
        b"fixture-bin/codex"
    );
}

#[test]
fn incomplete_or_corrupted_download_is_not_published_and_retry_succeeds() {
    let temp = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let (package, bytes) = fixture();
    assert!(
        prepare_with(temp.path(), workspace.path(), &package, || Ok(
            b"incomplete".to_vec()
        ))
        .is_err()
    );
    let directory = prepare_with(
        temp.path(),
        workspace.path(),
        &package,
        || Ok(bytes.clone()),
    )
    .unwrap();
    assert!(workspace.path().join(directory).join("bin/codex").exists());
    let key = hex::encode(&package.integrity);
    std::fs::write(
        temp.path()
            .join(format!("harness-cache/codex-{key}/package.tgz")),
        "corrupt",
    )
    .unwrap();
    prepare_with(temp.path(), workspace.path(), &package, || Ok(bytes)).unwrap();
}

#[test]
fn project_symlink_cannot_redirect_materialization() {
    let temp = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let victim = tempfile::tempdir().unwrap();
    let (package, bytes) = fixture();
    let directory = format!(".spark-codex-{}", &hex::encode(&package.integrity)[..16]);
    std::os::unix::fs::symlink(victim.path(), workspace.path().join(directory)).unwrap();
    assert!(prepare_with(temp.path(), workspace.path(), &package, || Ok(bytes)).is_err());
    assert_eq!(std::fs::read_dir(victim.path()).unwrap().count(), 0);
}

#[test]
fn simultaneous_projects_share_one_verified_download() {
    let cache = tempfile::tempdir().unwrap();
    let (package, bytes) = fixture();
    let downloads = AtomicUsize::new(0);
    std::thread::scope(|scope| {
        for _ in 0..4 {
            scope.spawn(|| {
                let project = tempfile::tempdir().unwrap();
                prepare_with(cache.path(), project.path(), &package, || {
                    downloads.fetch_add(1, Ordering::SeqCst);
                    Ok(bytes.clone())
                })
                .unwrap();
            });
        }
    });
    assert_eq!(downloads.load(Ordering::SeqCst), 1);
}

#[test]
#[ignore = "requires SPARK_TEST_CODEX_ARCHIVE and Docker with the pinned development image"]
fn real_pinned_package_runs_offline_in_two_isolated_projects() {
    let archive = std::env::var("SPARK_TEST_CODEX_ARCHIVE")
        .expect("explicitly provide the pinned Linux archive");
    let package = Package::pinned().unwrap();
    let cache = tempfile::tempdir().unwrap();
    for index in 0..2 {
        let project = tempfile::tempdir().unwrap();
        let directory = prepare_with(cache.path(), project.path(), &package, || {
            assert_eq!(index, 0, "the second project must work without a download");
            Ok(std::fs::read(&archive)?)
        })
        .unwrap();
        let uid = unsafe { libc::geteuid() };
        for binary in ["bin/codex", "codex-path/rg"] {
            let output = std::process::Command::new("docker")
                .args([
                    "run",
                    "--rm",
                    "--network=none",
                    "--read-only",
                    "--cap-drop=ALL",
                    "--security-opt=no-new-privileges:true",
                    &format!("--user={uid}:{uid}"),
                    &format!(
                        "--volume={}:/tools:ro",
                        project.path().join(&directory).display()
                    ),
                    spark_core::DEVELOPMENT_IMAGE,
                    &format!("/tools/{binary}"),
                    "--version",
                ])
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            let version = String::from_utf8_lossy(&output.stdout);
            assert!(
                version.contains(if binary == "bin/codex" {
                    "codex-cli 0.153.4"
                } else {
                    "ripgrep"
                }),
                "{version}"
            );
        }
    }
}

#[test]
fn a_project_fifo_is_replaced_without_blocking_and_execute_permissions_are_repaired() {
    use std::os::unix::fs::PermissionsExt as _;
    let cache = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let (package, bytes) = fixture();
    let directory = prepare_with(cache.path(), workspace.path(), &package, || Ok(bytes)).unwrap();
    let binary = workspace.path().join(&directory).join("bin/codex");
    std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o600)).unwrap();
    prepare_with(cache.path(), workspace.path(), &package, || {
        panic!("use verified cache")
    })
    .unwrap();
    assert_eq!(
        std::fs::metadata(&binary).unwrap().permissions().mode() & 0o700,
        0o700
    );
    std::fs::remove_file(&binary).unwrap();
    let path = std::ffi::CString::new(binary.to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    prepare_with(cache.path(), workspace.path(), &package, || {
        panic!("use verified cache")
    })
    .unwrap();
    assert!(std::fs::metadata(&binary).unwrap().is_file());
}
