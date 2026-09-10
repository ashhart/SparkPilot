use super::*;

fn valid_trust_root(path: &Path) {
    // Use a structurally valid schema-1 root with a parseable zero key for refusal paths that never verify signatures.
    let doc = serde_json::json!({
        "schema": 1,
        "keys": [{
            "key_id": "test-key",
            "algorithm": "ed25519",
            "public_key": "0".repeat(64),
            "channels": ["dev", "lab", "beta", "stable"],
            "purposes": ["release-manifest", "release-package"],
            "not_before": "2020-01-01T00:00:00Z",
            "not_after": "2036-01-01T00:00:00Z",
        }]
    });
    fs::write(path, serde_json::to_vec(&doc).unwrap()).unwrap();
}

#[test]
fn missing_manifest_refuses_before_staging() {
    let dir = tempfile::tempdir().unwrap();
    let trust = dir.path().join("trust.json");
    valid_trust_root(&trust);
    let request = ApplyRequest {
        manifest_path: &dir.path().join("absent.json"),
        package_path: &dir.path().join("package.deb"),
        signature_path: &dir.path().join("package.deb.sig"),
        trust_root: &trust,
        release_id: None,
        staging_root: &dir.path().join("updates"),
        privileged_socket: &dir.path().join("privd.sock"),
    };
    let error = run_apply(&request).unwrap_err();
    assert!(error.to_string().contains("No such file"), "{error}");
}

#[test]
fn sources_inside_the_staging_directory_are_refused_before_it_is_replaced() {
    let dir = tempfile::tempdir().unwrap();
    let staged = dir.path().join("updates").join("dev-0.1.1");
    fs::create_dir_all(&staged).unwrap();
    for name in ["manifest.json", "package.deb", "package.deb.sig"] {
        fs::write(staged.join(name), b"x").unwrap();
    }
    let error = refuse_sources_inside_staging(
        &staged,
        [
            &staged.join("manifest.json"),
            &dir.path().join("elsewhere.deb"),
            &staged.join("package.deb.sig"),
        ],
    )
    .unwrap_err();
    assert!(error.to_string().contains("staging replaces"), "{error}");
    for name in ["manifest.json", "package.deb", "package.deb.sig"] {
        assert!(staged.join(name).exists(), "nothing was deleted");
    }

    // Permit sources elsewhere and staging directories that do not yet exist.
    refuse_sources_inside_staging(
        &staged,
        [
            &dir.path().join("m.json"),
            &dir.path().join("p.deb"),
            &dir.path().join("p.sig"),
        ],
    )
    .unwrap();
    refuse_sources_inside_staging(
        &dir.path().join("updates").join("absent"),
        [
            &staged.join("manifest.json"),
            &staged.join("package.deb"),
            &staged.join("package.deb.sig"),
        ],
    )
    .unwrap();
}

#[test]
fn missing_trust_root_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let request = ApplyRequest {
        manifest_path: &dir.path().join("m.json"),
        package_path: &dir.path().join("p.deb"),
        signature_path: &dir.path().join("p.sig"),
        trust_root: &dir.path().join("absent-trust.json"),
        release_id: None,
        staging_root: &dir.path().join("updates"),
        privileged_socket: &dir.path().join("privd.sock"),
    };
    let error = run_apply(&request).unwrap_err();
    assert!(
        error.to_string().contains("UPDATE_NO_TRUST_ROOT"),
        "{error}"
    );
}

#[test]
fn derived_release_id_is_channel_version() {
    let manifest = ReleaseManifest {
        version: "0.1.0".into(),
        channel: "lab".into(),
        released_at: "2026-08-25T00:00:00Z".into(),
        minimum_dgx_os: "5.0".into(),
        maximum_dgx_os: None,
        api_version: None,
        artifacts: vec![],
        signature: None,
    };
    assert_eq!(derived_release_id(&manifest, "legacy.deb"), "lab-0.1.0");
}

#[test]
fn release_id_with_build_metadata_is_rejected_not_transformed() {
    let manifest = ReleaseManifest {
        version: "0.1.0+linux".into(),
        channel: "lab".into(),
        released_at: "2026-08-25T00:00:00Z".into(),
        minimum_dgx_os: "5.0".into(),
        maximum_dgx_os: None,
        api_version: None,
        artifacts: vec![],
        signature: None,
    };
    let derived = derived_release_id(&manifest, "legacy.deb");
    assert_eq!(derived, "lab-0.1.0+linux");
    assert!(spark_privd::update::validate_release_id(&derived).is_err());
}

#[test]
fn staging_refuses_a_symlink_without_touching_its_target() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("updates");
    let outside = dir.path().join("outside");
    fs::create_dir(&root).unwrap();
    fs::create_dir(&outside).unwrap();
    fs::write(outside.join("keep"), b"untouched").unwrap();
    let staged = root.join("lab-1.0.0");
    std::os::unix::fs::symlink(&outside, &staged).unwrap();
    let source = dir.path().join("source");
    fs::write(&source, b"bytes").unwrap();
    let request = ApplyRequest {
        manifest_path: &source,
        package_path: &source,
        signature_path: &source,
        trust_root: &source,
        release_id: Some("lab-1.0.0"),
        staging_root: &root,
        privileged_socket: &source,
    };
    assert!(stage_release(&staged, b"{}", &request).is_err());
    assert_eq!(fs::read(outside.join("keep")).unwrap(), b"untouched");
    assert_eq!(fs::read_dir(&outside).unwrap().count(), 1);
}

#[test]
fn staging_writes_fixed_names_readable_by_the_restricted_helper() {
    use std::os::unix::fs::PermissionsExt;

    let dir = tempfile::tempdir().unwrap();
    let staged_dir = dir.path().join("updates/lab-1.0.0");
    let manifest = dir.path().join("manifest.json");
    let package = dir.path().join("package.deb");
    let signature = dir.path().join("package.deb.sig");
    fs::write(&manifest, b"{}").unwrap();
    fs::write(&package, b"deb").unwrap();
    fs::write(&signature, b"sig").unwrap();
    let request = ApplyRequest {
        manifest_path: &manifest,
        package_path: &package,
        signature_path: &signature,
        trust_root: &dir.path().join("trust.json"),
        release_id: Some("lab-1.0.0"),
        staging_root: &dir.path().join("updates"),
        privileged_socket: &dir.path().join("privd.sock"),
    };
    stage_release(&staged_dir, b"{}", &request).unwrap();
    assert_eq!(fs::read(staged_dir.join("manifest.json")).unwrap(), b"{}");
    assert_eq!(fs::read(staged_dir.join("package.deb")).unwrap(), b"deb");
    assert_eq!(
        fs::read(staged_dir.join("package.deb.sig")).unwrap(),
        b"sig"
    );
    // Provide sparkd-group traversal/read access because root:sparkd privd lacks CAP_DAC_OVERRIDE.
    assert_eq!(
        fs::metadata(&staged_dir).unwrap().permissions().mode() & 0o777,
        0o750,
        "the helper group may traverse, but neither it nor others may write"
    );
    for name in [STAGED_MANIFEST, STAGED_PACKAGE, STAGED_SIGNATURE] {
        assert_eq!(
            fs::metadata(staged_dir.join(name))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o640,
            "the helper group may read {name}, but neither it nor others may write"
        );
    }
    // No `.part` leftovers remain after a clean stage.
    assert_eq!(
        fs::read_dir(&staged_dir).unwrap().count(),
        3,
        "only the three fixed files are staged"
    );
}

#[test]
fn restaging_waits_for_live_sealing_and_allows_immediate_retry_after_release() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("updates");
    let staged = root.join("lab-1.0.0");
    let source = dir.path().join("source");
    fs::write(&source, b"old").unwrap();
    let request = ApplyRequest {
        manifest_path: &source,
        package_path: &source,
        signature_path: &source,
        trust_root: &source,
        release_id: Some("lab-1.0.0"),
        staging_root: &root,
        privileged_socket: &source,
    };
    stage_release(&staged, b"old-manifest", &request).unwrap();
    // Separate descriptors must contend on the kernel lock held through validation and the final sealed-file copy.
    let reader = spark_privd::update::acquire_staging_lock(&root, false).unwrap();
    fs::write(&source, b"new").unwrap();
    let error = stage_release(&staged, b"new-manifest", &request).unwrap_err();
    assert!(error.to_string().contains("UPDATE_STAGING_BUSY"));
    assert_eq!(
        fs::read(staged.join(STAGED_MANIFEST)).unwrap(),
        b"old-manifest"
    );
    assert_eq!(fs::read(staged.join(STAGED_PACKAGE)).unwrap(), b"old");
    drop(reader);
    stage_release(&staged, b"new-manifest", &request).unwrap();
    assert_eq!(fs::read(staged.join(STAGED_PACKAGE)).unwrap(), b"new");
    let writer = spark_privd::update::acquire_staging_lock(&root, true).unwrap();
    assert!(spark_privd::update::acquire_staging_lock(&root, false).is_err());
    assert!(spark_privd::update::acquire_staging_lock(&root, true).is_err());
    drop(writer);
    assert!(spark_privd::update::acquire_staging_lock(&root, false).is_ok());
}

#[test]
fn restaging_replaces_stale_files() {
    let dir = tempfile::tempdir().unwrap();
    let package = dir.path().join("package.deb");
    let signature = dir.path().join("package.deb.sig");
    let manifest = dir.path().join("manifest.json");
    fs::write(&package, b"deb").unwrap();
    fs::write(&signature, b"sig").unwrap();
    fs::write(&manifest, b"{}").unwrap();
    let request = ApplyRequest {
        manifest_path: &manifest,
        package_path: &package,
        signature_path: &signature,
        trust_root: &dir.path().join("trust.json"),
        release_id: Some("lab-1.0.0"),
        staging_root: &dir.path().join("updates"),
        privileged_socket: &dir.path().join("privd.sock"),
    };
    let staged = dir.path().join("updates/lab-1.0.0");
    stage_release(&staged, b"{}", &request).unwrap();
    // Simulate a stale extra file that must not survive a re-stage.
    fs::write(staged.join("leftover"), b"x").unwrap();
    stage_release(&staged, b"{}", &request).unwrap();
    assert_eq!(fs::read_dir(&staged).unwrap().count(), 3);
    assert!(!staged.join("leftover").exists());
}

/// A delivered accepted:false helper response must make apply fail even though transport succeeded (H4).
#[test]
fn a_refused_install_is_an_error_not_a_successful_apply() {
    let accepted = PrivilegedResponse::ok(uuid::Uuid::nil(), "INSTALL_SCHEDULED", "scheduled");
    assert!(refusal(&accepted).is_none());

    let refused = PrivilegedResponse {
        request_id: uuid::Uuid::nil(),
        accepted: false,
        code: "UPDATE_STAGING_INVALID".to_owned(),
        message: "staged release does not verify".to_owned(),
        details: serde_json::Value::Null,
    };
    let error = refusal(&refused).expect("a refusal must not read as success");
    let text = error.to_string();
    assert!(text.contains("UPDATE_STAGING_INVALID"), "{text}");
    assert!(text.contains("staged release does not verify"), "{text}");
}

#[test]
fn validate_release_id_rejects_traversal_and_junk() {
    for bad in ["", "1abc", "..", ".", "a/b", "a b", "a\nb", "UPPER", "a"] {
        assert!(
            spark_privd::update::validate_release_id(bad).is_err(),
            "{bad:?} must be refused"
        );
    }
    for good in ["lab-0.1.0", "dev-1.2.3_rc.1", "stable-9.9.9"] {
        assert!(
            spark_privd::update::validate_release_id(good).is_ok(),
            "{good:?} must be accepted"
        );
    }
}

#[test]
fn derived_release_ids_distinguish_revisions_of_the_same_runtime() {
    let ids: Vec<_> = [2, 3]
        .into_iter()
        .map(|revision| {
            let manifest: ReleaseManifest = serde_json::from_value(serde_json::json!({
                "version": "0.1.13", "channel": "dev", "released_at": "2026-09-07T00:00:00Z",
                "minimum_dgx_os": "7.0", "artifacts": [{
                    "name": format!("spark-runtime_0.1.13-0qa20260907.{revision}_arm64.deb"),
                    "architecture": "aarch64", "url": "https://example.invalid/runtime.deb",
                    "size": 1, "sha256": "a".repeat(64),
                    "signature_url": "https://example.invalid/runtime.deb.sig"
                }]
            }))
            .unwrap();
            derived_release_id(&manifest, &manifest.artifacts[0].name)
        })
        .collect();
    assert_eq!(
        ids,
        ["dev-0.1.13-0qa20260907.2", "dev-0.1.13-0qa20260907.3"]
    );
}
