use super::*;
use ed25519_dalek::{Signer, SigningKey};
use time::format_description::well_known::Rfc3339;

fn signing_key() -> SigningKey {
    SigningKey::from_bytes(&[3u8; 32])
}

fn trust_root() -> ReleaseTrustRoot {
    let public = hex::encode(signing_key().verifying_key().to_bytes());
    let json = serde_json::json!({
        "schema": 1,
        "keys": [{
            "key_id": "test-key",
            "algorithm": "ed25519",
            "public_key": public,
            "channels": ["dev"],
            "purposes": ["release-manifest", "release-package"],
            "not_before": "2026-01-01T00:00:00Z",
            "not_after": "2027-01-01T00:00:00Z"
        }]
    })
    .to_string();
    ReleaseTrustRoot::from_json(json.as_bytes()).unwrap()
}

fn write(dir: &Path, name: &str, contents: &[u8]) -> std::path::PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, contents).unwrap();
    path
}

fn artifact_for(name: &str, contents: &[u8]) -> ReleaseArtifact {
    ReleaseArtifact {
        name: name.to_owned(),
        architecture: "aarch64".into(),
        url: format!("https://x.invalid/{name}"),
        size: contents.len() as u64,
        sha256: hex::encode(Sha256::digest(contents)),
        signature_url: format!("https://x.invalid/{name}.sig"),
    }
}

fn now() -> OffsetDateTime {
    OffsetDateTime::parse("2026-08-27T00:00:00Z", &Rfc3339).unwrap()
}

fn signed_manifest(artifacts: Vec<ReleaseArtifact>) -> ReleaseManifest {
    let mut manifest = ReleaseManifest {
        version: "0.1.0".into(),
        channel: "dev".into(),
        released_at: "2026-08-27T00:00:00Z".into(),
        minimum_dgx_os: "7.0".into(),
        maximum_dgx_os: None,
        api_version: Some(1),
        artifacts,
        signature: None,
    };
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let canonical = manifest.canonical_bytes().unwrap();
    manifest.signature = Some(crate::manifest::ManifestSignature {
        key_id: "test-key".into(),
        algorithm: "ed25519".into(),
        value: URL_SAFE_NO_PAD.encode(signing_key().sign(&canonical).to_bytes()),
    });
    manifest
}

#[test]
fn a_correctly_signed_artifact_verifies() {
    let dir = tempfile::tempdir().unwrap();
    let contents = b"a real package".to_vec();
    let path = write(dir.path(), "a.deb", &contents);
    let signature = signing_key().sign(&contents).to_bytes();

    let report = verify_artifact(
        &path,
        &ArtifactVerification {
            artifact: &artifact_for("a.deb", &contents),
            channel: "dev",
            trust_root: &trust_root(),
            trust_root_source: TrustRootSource::Installed,
            signature: &signature,
            key_id: "test-key",
            at: now(),
        },
    )
    .unwrap();
    assert_eq!(report.signature_key_id, "test-key");
    assert_eq!(report.trust_root_source, TrustRootSource::Installed);
}

#[test]
fn oversized_artifact_is_refused_before_content_verification() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("large.deb");
    std::fs::File::create(&path)
        .unwrap()
        .set_len(65 * 1024 * 1024)
        .unwrap();
    let mut artifact = artifact_for("large.deb", b"small signed package");
    artifact.size = 65 * 1024 * 1024;
    let signature = signing_key().sign(b"small signed package").to_bytes();
    let error = verify_artifact(
        &path,
        &ArtifactVerification {
            artifact: &artifact,
            channel: "dev",
            trust_root: &trust_root(),
            trust_root_source: TrustRootSource::Installed,
            signature: &signature,
            key_id: "test-key",
            at: now(),
        },
    )
    .unwrap_err();
    assert!(
        error.to_string().contains("limit"),
        "must refuse the size before allocating or hashing the package: {error}"
    );
}

#[test]
fn an_empty_signature_is_rejected_as_missing() {
    let dir = tempfile::tempdir().unwrap();
    let contents = b"a real package".to_vec();
    let path = write(dir.path(), "a.deb", &contents);

    assert!(matches!(
        verify_artifact(
            &path,
            &ArtifactVerification {
                artifact: &artifact_for("a.deb", &contents),
                channel: "dev",
                trust_root: &trust_root(),
                trust_root_source: TrustRootSource::Supplied,
                signature: &[],
                key_id: "test-key",
                at: now(),
            },
        ),
        Err(VerifyError::MissingSignature(_))
    ));
}

#[test]
fn a_short_signature_is_rejected_before_the_file_is_even_read() {
    let dir = tempfile::tempdir().unwrap();
    let artifact = artifact_for("a.deb", b"a real package");
    assert!(matches!(
        verify_artifact(
            &dir.path().join("absent.deb"),
            &ArtifactVerification {
                artifact: &artifact,
                channel: "dev",
                trust_root: &trust_root(),
                trust_root_source: TrustRootSource::Supplied,
                signature: &[0u8; 10],
                key_id: "test-key",
                at: now(),
            },
        ),
        Err(VerifyError::MalformedSignature(10))
    ));
}

#[test]
fn a_flipped_byte_fails_the_digest_check() {
    let dir = tempfile::tempdir().unwrap();
    let artifact = artifact_for("a.deb", b"a real package");
    let path = write(dir.path(), "a.deb", b"a real packag3");
    let signature = signing_key().sign(b"a real packag3").to_bytes();
    assert!(matches!(
        verify_artifact(
            &path,
            &ArtifactVerification {
                artifact: &artifact,
                channel: "dev",
                trust_root: &trust_root(),
                trust_root_source: TrustRootSource::Installed,
                signature: &signature,
                key_id: "test-key",
                at: now(),
            },
        ),
        Err(VerifyError::DigestMismatch { .. })
    ));
}

#[test]
fn a_truncated_transfer_fails_before_the_digest() {
    let dir = tempfile::tempdir().unwrap();
    let artifact = artifact_for("a.deb", b"a real package");
    let path = write(dir.path(), "a.deb", b"a real");
    let signature = signing_key().sign(b"a real").to_bytes();
    assert!(matches!(
        verify_artifact(
            &path,
            &ArtifactVerification {
                artifact: &artifact,
                channel: "dev",
                trust_root: &trust_root(),
                trust_root_source: TrustRootSource::Installed,
                signature: &signature,
                key_id: "test-key",
                at: now(),
            },
        ),
        Err(VerifyError::SizeMismatch {
            expected: 14,
            actual: 6
        })
    ));
}

#[test]
fn a_signature_from_another_key_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let contents = b"a real package".to_vec();
    let path = write(dir.path(), "a.deb", &contents);
    let attacker = SigningKey::from_bytes(&[9u8; 32]);
    let signature = attacker.sign(&contents).to_bytes();

    assert!(matches!(
        verify_artifact(
            &path,
            &ArtifactVerification {
                artifact: &artifact_for("a.deb", &contents),
                channel: "dev",
                trust_root: &trust_root(),
                trust_root_source: TrustRootSource::Installed,
                signature: &signature,
                key_id: "test-key",
                at: now(),
            },
        ),
        Err(VerifyError::Trust(TrustError::SignatureInvalid(_)))
    ));
}

#[test]
fn a_signature_over_a_different_artifact_is_rejected() {
    // Lifting a valid signature from one release onto another must fail.
    let dir = tempfile::tempdir().unwrap();
    let contents = b"a real package".to_vec();
    let path = write(dir.path(), "a.deb", &contents);
    let signature = signing_key().sign(b"a different package").to_bytes();

    assert!(matches!(
        verify_artifact(
            &path,
            &ArtifactVerification {
                artifact: &artifact_for("a.deb", &contents),
                channel: "dev",
                trust_root: &trust_root(),
                trust_root_source: TrustRootSource::Installed,
                signature: &signature,
                key_id: "test-key",
                at: now(),
            },
        ),
        Err(VerifyError::Trust(TrustError::SignatureInvalid(_)))
    ));
}

#[test]
fn a_missing_file_is_an_io_error_not_a_pass() {
    let dir = tempfile::tempdir().unwrap();
    let artifact = artifact_for("a.deb", b"a real package");
    let signature = signing_key().sign(b"a real package").to_bytes();
    assert!(matches!(
        verify_artifact(
            &dir.path().join("absent.deb"),
            &ArtifactVerification {
                artifact: &artifact,
                channel: "dev",
                trust_root: &trust_root(),
                trust_root_source: TrustRootSource::Installed,
                signature: &signature,
                key_id: "test-key",
                at: now(),
            },
        ),
        Err(VerifyError::Io { .. })
    ));
}

#[test]
fn constructed_manifest_cannot_read_an_artifact_outside_its_directory() {
    let dir = tempfile::tempdir().unwrap();
    let artifacts = dir.path().join("artifacts");
    std::fs::create_dir(&artifacts).unwrap();
    write(dir.path(), "outside.deb", b"outside");
    let manifest = signed_manifest(vec![artifact_for("../outside.deb", b"outside")]);
    let mut signature_read = false;
    let result = verify_release(
        &manifest,
        &artifacts,
        &trust_root(),
        TrustRootSource::Installed,
        now(),
        |_| {
            signature_read = true;
            Some(signing_key().sign(b"outside").to_bytes().to_vec())
        },
    );
    assert!(result.is_err());
    assert!(
        !signature_read,
        "names must be checked before asking a caller to read a signature"
    );
}

#[test]
fn a_fully_signed_release_verifies_every_artifact() {
    let dir = tempfile::tempdir().unwrap();
    let first = b"package one".to_vec();
    let second = b"package two".to_vec();
    write(dir.path(), "one.deb", &first);
    write(dir.path(), "two.deb", &second);
    let manifest = signed_manifest(vec![
        artifact_for("one.deb", &first),
        artifact_for("two.deb", &second),
    ]);

    let reports = verify_release(
        &manifest,
        dir.path(),
        &trust_root(),
        TrustRootSource::Installed,
        now(),
        |artifact| {
            let contents = std::fs::read(dir.path().join(&artifact.name)).ok()?;
            Some(signing_key().sign(&contents).to_bytes().to_vec())
        },
    )
    .unwrap();
    assert_eq!(reports.len(), 2);
}

#[test]
fn a_partially_signed_release_is_rejected_whole() {
    let dir = tempfile::tempdir().unwrap();
    let first = b"package one".to_vec();
    let second = b"package two".to_vec();
    write(dir.path(), "one.deb", &first);
    write(dir.path(), "two.deb", &second);
    let manifest = signed_manifest(vec![
        artifact_for("one.deb", &first),
        artifact_for("two.deb", &second),
    ]);

    // The first artifact is signed, the second is not.
    let error = verify_release(
        &manifest,
        dir.path(),
        &trust_root(),
        TrustRootSource::Installed,
        now(),
        |artifact| {
            if artifact.name == "two.deb" {
                return None;
            }
            let contents = std::fs::read(dir.path().join(&artifact.name)).ok()?;
            Some(signing_key().sign(&contents).to_bytes().to_vec())
        },
    )
    .unwrap_err();
    assert!(matches!(error, VerifyError::MissingSignature(name) if name == "two.deb"));
}

#[test]
fn a_release_whose_manifest_is_unsigned_verifies_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let contents = b"package one".to_vec();
    write(dir.path(), "one.deb", &contents);
    let mut manifest = signed_manifest(vec![artifact_for("one.deb", &contents)]);
    manifest.signature = None;

    assert!(matches!(
        verify_release(
            &manifest,
            dir.path(),
            &trust_root(),
            TrustRootSource::Installed,
            now(),
            |_| Some(vec![0u8; SIGNATURE_BYTES]),
        ),
        Err(VerifyError::UnsignedManifest)
    ));
}

#[test]
fn signature_files_are_read_in_raw_and_text_form() {
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let dir = tempfile::tempdir().unwrap();
    let raw = signing_key().sign(b"payload").to_bytes();

    let raw_path = write(dir.path(), "raw.sig", &raw);
    assert_eq!(read_signature(&raw_path).unwrap(), raw.to_vec());

    let text_path = write(
        dir.path(),
        "text.sig",
        format!("{}\n", URL_SAFE_NO_PAD.encode(raw)).as_bytes(),
    );
    assert_eq!(read_signature(&text_path).unwrap(), raw.to_vec());

    let empty_path = write(dir.path(), "empty.sig", b"");
    assert!(matches!(
        read_signature(&empty_path),
        Err(VerifyError::MalformedSignature(0))
    ));

    let short_path = write(dir.path(), "short.sig", b"AAAA");
    assert!(matches!(
        read_signature(&short_path),
        Err(VerifyError::MalformedSignature(3))
    ));

    assert!(matches!(
        read_signature(&dir.path().join("absent.sig")),
        Err(VerifyError::Io { .. })
    ));
}

/// A signature name that is a link, or a file far larger than any signature, is refused without being read through.
#[test]
fn signature_files_are_opened_without_following_links_and_within_a_bound() {
    let dir = tempfile::tempdir().unwrap();
    let raw = signing_key().sign(b"payload").to_bytes();
    let target = write(dir.path(), "target.sig", &raw);
    let link = dir.path().join("link.sig");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    assert!(matches!(read_signature(&link), Err(VerifyError::Io { .. })));

    let huge = write(
        dir.path(),
        "huge.sig",
        &vec![b'A'; MAX_SIGNATURE_FILE_BYTES as usize + 1],
    );
    assert!(matches!(
        read_signature(&huge),
        Err(VerifyError::MalformedSignature(_))
    ));
    assert!(matches!(
        read_signature(dir.path()),
        Err(VerifyError::Io { .. })
    ));
}
