use super::*;

pub(super) struct Artifacts<'a> {
    pub(super) db: &'a Mutex<rusqlite::Connection>,
    pub(super) jobs: &'a JobService,
    pub(super) work_dir: &'a Path,
    pub(super) claims: claims::Claims<'a>,
}

impl Artifacts<'_> {
    pub fn store_artifact(
        &self,
        build_id: &Uuid,
        worker_id: &Uuid,
        claim_token: &str,
        artifact_token: &str,
        evidence: &BuildArtifactEvidence,
        bytes: &[u8],
    ) -> Result<(), &'static str> {
        let conn = self.db.lock();
        let build = self
            .claims
            .verify_claim_locked(&conn, build_id, worker_id, claim_token)?;
        if evidence.size_bytes != bytes.len() as u64
            || evidence.size_bytes > MAX_ARTIFACT_BYTES
            || crate::crypto::sha256_hex(bytes) != evidence.sha256
            || !safe_relative_path(&evidence.relative_path)
        {
            return Err("BUILD_ARTIFACT_INVALID");
        }
        let Some(stored) = build.artifact_token_hash.as_ref() else {
            return Err("BUILD_ARTIFACT_TICKET_INVALID");
        };
        let presented = crate::crypto::sha256_hex(artifact_token.as_bytes()).into_bytes();
        if !constant_time_eq(stored, &presented) {
            return Err("BUILD_ARTIFACT_TICKET_INVALID");
        }
        if let Some(stored) = store::build_artifacts(&conn, build_id, build.claim_generation)
            .map_err(|_| "BUILD_ARTIFACT_STORE_FAILED")?
            .into_iter()
            .find(|stored| stored.id == evidence.artifact_id)
        {
            let exact = stored.worker_id == *worker_id
                && stored.kind == evidence.kind
                && stored.relative_path == evidence.relative_path
                && stored.sha256 == evidence.sha256
                && stored.size_bytes == evidence.size_bytes;
            let path = self
                .work_dir
                .join("builds")
                .join(build_id.to_string())
                .join(build.claim_generation.to_string())
                .join("artifacts")
                .join(evidence.artifact_id.to_string());
            let bytes_match = std::fs::read(path)
                .ok()
                .is_some_and(|stored_bytes| stored_bytes == bytes);
            return if exact && bytes_match {
                Ok(())
            } else {
                Err("BUILD_ARTIFACT_ALREADY_EXISTS")
            };
        }
        let (count, total) = store::build_artifact_usage(&conn, build_id, build.claim_generation)
            .map_err(|_| "BUILD_ARTIFACT_STORE_FAILED")?;
        if count >= u64::from(MAX_ARTIFACTS)
            || total.saturating_add(evidence.size_bytes) > MAX_ARTIFACT_TOTAL_BYTES
        {
            return Err("BUILD_ARTIFACT_LIMIT_EXCEEDED");
        }
        let storage_root = self.work_dir.join("builds");
        if directory_size(&storage_root)
            .unwrap_or(BUILD_ARTIFACT_STORAGE_LIMIT_BYTES)
            .saturating_add(evidence.size_bytes)
            > BUILD_ARTIFACT_STORAGE_LIMIT_BYTES
        {
            return Err("BUILD_ARTIFACT_STORAGE_FULL");
        }
        let directory = self
            .work_dir
            .join("builds")
            .join(build_id.to_string())
            .join(build.claim_generation.to_string())
            .join("artifacts");
        write_artifact(&directory, &evidence.artifact_id, bytes)
            .map_err(|_| "BUILD_ARTIFACT_STORE_FAILED")?;
        let row = store::BuildArtifactRow {
            id: evidence.artifact_id,
            build_id: *build_id,
            operation_id: build.operation_id,
            project_id: build.project_id,
            worker_id: *worker_id,
            claim_generation: build.claim_generation,
            kind: evidence.kind.clone(),
            relative_path: evidence.relative_path.clone(),
            sha256: evidence.sha256.clone(),
            size_bytes: evidence.size_bytes,
            created_at: self.jobs.now_rfc3339(),
        };
        if store::insert_build_artifact(&conn, &row).is_err() {
            let _ = std::fs::remove_file(directory.join(evidence.artifact_id.to_string()));
            return Err("BUILD_ARTIFACT_STORE_FAILED");
        }
        self.claims.announce(
            Some(&conn),
            Some(build.operation_id),
            "build.artifact.ready",
            "info",
            json!({
                "build_id": build_id,
                "artifact_id": row.id,
                "kind": row.kind,
                "size_bytes": row.size_bytes,
                "sha256": row.sha256,
            }),
            crate::events::Visibility::project(build.project_id),
        );
        Ok(())
    }

    pub fn read_artifact(
        &self,
        build_id: &Uuid,
        artifact_id: &Uuid,
    ) -> Result<(store::BuildArtifactRow, Vec<u8>), &'static str> {
        let conn = self.db.lock();
        let build = store::build_row(&conn, build_id)
            .map_err(|_| "BUILD_NOT_FOUND")?
            .ok_or("BUILD_NOT_FOUND")?;
        if !matches!(build.status.as_str(), "completed" | "failed" | "cancelled") {
            return Err("BUILD_ARTIFACT_NOT_READY");
        }
        let artifact = store::build_artifact(&conn, build_id, artifact_id)
            .map_err(|_| "BUILD_ARTIFACT_NOT_FOUND")?
            .filter(|row| row.claim_generation == build.claim_generation)
            .ok_or("BUILD_ARTIFACT_NOT_FOUND")?;
        let path = self
            .work_dir
            .join("builds")
            .join(build_id.to_string())
            .join(artifact.claim_generation.to_string())
            .join("artifacts")
            .join(artifact.id.to_string());
        let bytes = std::fs::read(path).map_err(|_| "BUILD_ARTIFACT_NOT_FOUND")?;
        if bytes.len() as u64 != artifact.size_bytes
            || crate::crypto::sha256_hex(&bytes) != artifact.sha256
        {
            return Err("BUILD_ARTIFACT_CORRUPT");
        }
        Ok((artifact, bytes))
    }
}

fn directory_size(path: &Path) -> std::io::Result<u64> {
    let mut total = 0u64;
    if !path.exists() {
        return Ok(0);
    }
    for entry in std::fs::read_dir(path)? {
        let entry = entry?;
        let metadata = entry.metadata()?;
        total = total.saturating_add(if metadata.is_dir() {
            directory_size(&entry.path())?
        } else {
            metadata.len()
        });
    }
    Ok(total)
}

fn write_artifact(directory: &Path, id: &Uuid, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true).mode(0o700).create(directory)?;
    let destination = directory.join(id.to_string());
    let temporary = directory.join(format!(".{}.{}.tmp", id, Uuid::new_v4()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    match std::fs::hard_link(&temporary, &destination) {
        Ok(()) => {
            std::fs::remove_file(&temporary)?;
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            let exact = std::fs::read(&destination).is_ok_and(|stored| stored == bytes);
            std::fs::remove_file(&temporary)?;
            if exact { Ok(()) } else { Err(error) }
        }
        Err(error) => {
            let _ = std::fs::remove_file(&temporary);
            Err(error)
        }
    }
}
