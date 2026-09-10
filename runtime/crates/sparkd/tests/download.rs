//! Exercise successful downloads, interrupt/resume, digest refusal, cancellation cleanup and disk preflight.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use parking_lot::Mutex;
use rusqlite::Connection;
use spark_models::recipe::fixture::RecipeFixture;
use spark_models::{ModelRecipe, RemoteFile};
use sparkd::download::{
    self, CancelFlag, DownloadContext, DownloadCoordinator, FileSource, ProgressSink,
    SourceResolver,
};

struct MemResolver {
    files: Vec<RemoteFile>,
}

impl MemResolver {
    fn new(files: Vec<RemoteFile>) -> Self {
        Self { files }
    }
}

impl SourceResolver for MemResolver {
    fn resolve(&self, _recipe: &ModelRecipe) -> Result<Vec<RemoteFile>, String> {
        Ok(self.files.clone())
    }
}

/// Serves exact ranges; on error returns an Error after `fail_at` bytes.
struct MemSource {
    data: HashMap<String, Vec<u8>>,
    fail_at: Option<usize>,
    served: Arc<AtomicUsize>,
}

impl FileSource for MemSource {
    fn fetch(
        &self,
        _recipe: &ModelRecipe,
        file: &RemoteFile,
        range: Option<(u64, usize)>,
    ) -> Result<Vec<u8>, String> {
        let full = self
            .data
            .get(&file.relative_path)
            .cloned()
            .unwrap_or_default();
        let (offset, len) = range.unwrap_or((0, full.len()));
        let end = ((offset as usize) + len).min(full.len());
        let slice = full[offset as usize..end].to_vec();

        let served_so_far = self.served.load(Ordering::SeqCst);
        if let Some(fail_at) = self.fail_at {
            if served_so_far >= fail_at {
                return Err("simulated source failure".into());
            }
            // Persist bytes up to the injected failure boundary before raising the simulated interruption.
            let deliver = (fail_at - served_so_far).min(slice.len());
            self.served.fetch_add(deliver, Ordering::SeqCst);
            return Ok(slice[..deliver].to_vec());
        }
        self.served.fetch_add(slice.len(), Ordering::SeqCst);
        Ok(slice)
    }
}

/// No-op progress sink.
struct NullSink;
impl ProgressSink for NullSink {
    fn note(
        &self,
        _relative_path: &str,
        _file_index: usize,
        _total: usize,
        _done: u64,
        _total_bytes: u64,
    ) -> Result<(), String> {
        Ok(())
    }
}

fn fixture_files(data: &[(&str, Vec<u8>)]) -> (Vec<RemoteFile>, HashMap<String, Vec<u8>>) {
    let mut files = Vec::new();
    let mut map = HashMap::new();
    for (name, bytes) in data {
        let digest = sha256_hex(bytes);
        files.push(RemoteFile {
            relative_path: name.to_string(),
            size_bytes: bytes.len() as u64,
            sha256: digest,
        });
        map.insert(name.to_string(), bytes.clone());
    }
    (files, map)
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(bytes))
}

struct Harness {
    database: Mutex<Connection>,
    recipe: ModelRecipe,
    dir: tempfile::TempDir,
    served: Arc<AtomicUsize>,
}

fn harness(_data: &[(&str, Vec<u8>)]) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let mut conn = Connection::open_in_memory().unwrap();
    sparkd::migration::migrate(&mut conn).unwrap();
    let recipe = RecipeFixture::example();
    // Use a repository and revision accepted by snapshot path validation.
    sparkd::store::upsert_catalogue_model(&conn, &recipe).unwrap();
    conn.execute(
        "UPDATE models SET id = 'example/model-32b' WHERE id = 'example/model-32b'",
        [],
    )
    .unwrap();
    Harness {
        database: Mutex::new(conn),
        recipe,
        dir,
        served: Arc::new(AtomicUsize::new(0)),
    }
}

fn ctx(root: &Path, cancel: &CancelFlag, disk_free: u64) -> DownloadContext {
    DownloadContext {
        root: root.to_path_buf(),
        cancel: Arc::new(cancel.clone()),
        disk_free_bytes: disk_free,
        disk_reserve_bytes: 0,
        fetches: Arc::new(AtomicUsize::new(0)),
    }
}

include!("download/scenarios/full_download_verifies_and_materialises.rs");

include!("download/scenarios/wrong_digest_never_installs_and_cleans_partial.rs");

include!("download/scenarios/interrupt_then_resume_completes.rs");

include!("download/scenarios/oversized_partial_is_truncated_and_one_retry_succeeds.rs");

include!("download/scenarios/verified_target_is_reused_without_refetching.rs");

include!("download/scenarios/same_size_corrupted_target_is_rejected_and_refetched.rs");

include!("download/scenarios/symlinked_target_is_never_followed_or_reused.rs");

include!("download/scenarios/symlinked_oversized_partial_never_truncates_the_link_destination.rs");

include!("download/scenarios/cancellation_stops_before_any_materialisation.rs");

include!("download/scenarios/disk_preflight_blocks_oversized_downloads.rs");

include!("download/scenarios/disk_preflight_uses_the_disk_reserve_not_the_memory_reserve.rs");

include!("download/scenarios/remote_manifest_paths_cannot_escape_the_download_root.rs");

struct CredentialAwareSource {
    data: Vec<u8>,
    expected_credential: std::path::PathBuf,
}

impl FileSource for CredentialAwareSource {
    fn fetch(
        &self,
        _recipe: &ModelRecipe,
        _file: &RemoteFile,
        _range: Option<(u64, usize)>,
    ) -> Result<Vec<u8>, String> {
        Err("credential-aware fetch path was bypassed".into())
    }

    fn fetch_with_credential(
        &self,
        _recipe: &ModelRecipe,
        _file: &RemoteFile,
        range: Option<(u64, usize)>,
        credential_path: Option<&Path>,
    ) -> Result<Vec<u8>, String> {
        assert_eq!(credential_path, Some(self.expected_credential.as_path()));
        assert_eq!(
            std::fs::read_to_string(credential_path.unwrap()).unwrap(),
            "hf_read_only_token"
        );
        let (offset, len) = range.unwrap_or((0, self.data.len()));
        let end = (offset as usize + len).min(self.data.len());
        Ok(self.data[offset as usize..end].to_vec())
    }
}

include!("download/scenarios/credential_reference_reaches_only_the_source_boundary.rs");

/// Records the durable stages an install reports, in order.
#[derive(Default)]
struct RecordingSink {
    seen: Mutex<Vec<(String, Option<f64>)>>,
}

impl ProgressSink for RecordingSink {
    fn note(
        &self,
        _relative_path: &str,
        _file_index: usize,
        _total: usize,
        _done: u64,
        _total_bytes: u64,
    ) -> Result<(), String> {
        Ok(())
    }

    fn stage(&self, stage: &str, progress: Option<f64>) {
        self.seen.lock().push((stage.to_owned(), progress));
    }
}

include!("download/scenarios/install_stages_are_ordered_and_the_fraction_never_goes_backwards.rs");

include!("download/scenarios/a_resumed_install_starts_from_the_bytes_already_verified.rs");
