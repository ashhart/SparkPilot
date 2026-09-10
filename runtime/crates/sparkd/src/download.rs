//! Resume immutable downloads and verify SHA-256 before exposing fully materialized installed snapshots.

use std::path::{Path, PathBuf};

use std::sync::Arc;

use std::sync::atomic::{AtomicUsize, Ordering};

use parking_lot::Mutex;

use rusqlite::{Connection, TransactionBehavior};

use thiserror::Error;

use spark_models::{ModelRecipe, RemoteFile};

/// Resolves the immutable file list of a model revision.
pub trait SourceResolver: Send + Sync {
    fn resolve(&self, recipe: &ModelRecipe) -> Result<Vec<RemoteFile>, String>;

    /// Read provider secrets only at the network boundary; keep credential contents outside operation state.
    fn resolve_with_credential(
        &self,
        recipe: &ModelRecipe,
        _credential_path: Option<&Path>,
    ) -> Result<Vec<RemoteFile>, String> {
        self.resolve(recipe)
    }
}

/// Fetch the exact requested byte range or the complete file when no range is supplied.
pub trait FileSource: Send + Sync {
    fn fetch(
        &self,
        recipe: &ModelRecipe,
        file: &RemoteFile,
        range: Option<(u64, usize)>,
    ) -> Result<Vec<u8>, String>;

    /// Read optional credentials only while building authenticated requests; public sources keep the default implementation.
    fn fetch_with_credential(
        &self,
        recipe: &ModelRecipe,
        file: &RemoteFile,
        range: Option<(u64, usize)>,
        _credential_path: Option<&Path>,
    ) -> Result<Vec<u8>, String> {
        self.fetch(recipe, file, range)
    }
}

#[derive(Debug, Error)]
pub enum DownloadError {
    #[error("disk preflight failed: need {need} bytes, have {have}")]
    InsufficientDisk { need: u64, have: u64 },
    #[error("digest mismatch for {file}: wanted {want}, got {got}")]
    DigestMismatch {
        file: String,
        want: String,
        got: String,
    },
    #[error("cancelled")]
    Cancelled,
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("source error: {0}")]
    Source(String),
    #[error("internal: {0}")]
    Internal(String),
}

pub type Result<T, E = DownloadError> = std::result::Result<T, E>;

/// Anything that can be asked whether the download should stop.
pub trait IsCancelled: Send + Sync {
    fn is_set(&self) -> bool;
}

pub struct DownloadContext {
    pub root: PathBuf,
    pub cancel: Arc<dyn IsCancelled>,
    /// Free disk for preflight; real value injected by the caller.
    pub disk_free_bytes: u64,
    /// Reserve disk capacity independently of the recipe's unified-memory reserve.
    pub disk_reserve_bytes: u64,
    /// Fetch accounting for resume tests.
    pub fetches: Arc<AtomicUsize>,
}

/// Default free-disk headroom kept after an install.
pub const DEFAULT_DISK_RESERVE_BYTES: u64 = 4 * 1024 * 1024 * 1024;

impl DownloadContext {
    pub fn check_cancel(&self) -> Result<()> {
        if self.cancel.is_set() {
            return Err(DownloadError::Cancelled);
        }
        Ok(())
    }
}

impl IsCancelled for CancelFlag {
    fn is_set(&self) -> bool {
        CancelFlag::is_set(self)
    }
}

/// Share cooperative cancellation through an Arc-backed flag.
#[derive(Debug, Default, Clone)]
pub struct CancelFlag(Arc<AtomicUsize>);

impl CancelFlag {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn set(&self) {
        self.0.store(1, Ordering::SeqCst);
    }
    pub fn is_set(&self) -> bool {
        self.0.load(Ordering::SeqCst) == 1
    }
}

/// Per-attempt progress sink (database and event updates).
pub trait ProgressSink {
    fn note(
        &self,
        relative_path: &str,
        file_index: usize,
        total_files: usize,
        bytes_done: u64,
        bytes_total: u64,
    ) -> std::result::Result<(), String>;

    /// Report whole-install progress only when measurable; stage reporting cannot fail downloads or reuse resetting per-file fractions.
    fn stage(&self, _stage: &str, _progress: Option<f64>) {}
}

/// Check disk capacity independently of upstream unified-memory admission.
pub fn disk_preflight(
    disk_free_bytes: u64,
    required_bytes: u64,
    minimum_reserve: u64,
) -> Result<()> {
    let need = required_bytes.saturating_add(minimum_reserve);
    if disk_free_bytes < need {
        return Err(DownloadError::InsufficientDisk {
            need,
            have: disk_free_bytes,
        });
    }
    Ok(())
}

/// Total expected bytes across resolved files.
pub fn total_bytes(files: &[RemoteFile]) -> u64 {
    // Saturate declared-byte totals so overflow cannot bypass disk reservation.
    files
        .iter()
        .map(|f| f.size_bytes)
        .fold(0u64, u64::saturating_add)
}

/// Count only staged files verified against the immutable manifest; exclude unverified partial prefixes.
pub fn verified_reusable_bytes(
    root: &Path,
    recipe: &ModelRecipe,
    files: &[RemoteFile],
) -> Result<u64> {
    reusable_bytes_with_budget(root, recipe, files, u64::MAX)
}

/// Preview credits only bounded checksum work; the install worker verifies every staged weight.
pub fn preview_reusable_bytes(
    root: &Path,
    recipe: &ModelRecipe,
    files: &[RemoteFile],
) -> Result<u64> {
    reusable_bytes_with_budget(root, recipe, files, 32 * 1024 * 1024)
}

fn reusable_bytes_with_budget(
    root: &Path,
    recipe: &ModelRecipe,
    files: &[RemoteFile],
    mut budget: u64,
) -> Result<u64> {
    let work_dir = work_dir(root, recipe)?;
    let mut reusable = 0_u64;
    for file in files {
        if file.size_bytes > budget {
            continue;
        }
        budget -= file.size_bytes;
        let target = crate::model_paths::relative_join(&work_dir, &file.relative_path)
            .map_err(DownloadError::Source)?;
        let Ok(metadata) = std::fs::symlink_metadata(&target) else {
            continue;
        };
        if metadata.is_file()
            && metadata.len() == file.size_bytes
            && matches!(sha256_regular_no_follow(&target), Ok(digest) if digest.eq_ignore_ascii_case(&file.sha256))
        {
            reusable = reusable.saturating_add(file.size_bytes);
        }
    }
    Ok(reusable)
}

/// Resolve, preflight, stage, verify and materialize trusted snapshots with optional database state transitions.
pub struct DownloadCoordinator {
    pub resolver: Box<dyn SourceResolver>,
    pub source: Box<dyn FileSource>,
}

impl DownloadCoordinator {
    pub fn install(
        &self,
        database: &Mutex<Connection>,
        recipe: &ModelRecipe,
        ctx: &DownloadContext,
        progress: &dyn ProgressSink,
        models_root: &Path,
    ) -> Result<()> {
        self.install_with_credential(database, recipe, ctx, progress, models_root, None)
    }

    pub fn install_with_credential(
        &self,
        database: &Mutex<Connection>,
        recipe: &ModelRecipe,
        ctx: &DownloadContext,
        progress: &dyn ProgressSink,
        models_root: &Path,
        credential_path: Option<&Path>,
    ) -> Result<()> {
        ctx.check_cancel()?;

        let files = self
            .resolver
            .resolve_with_credential(recipe, credential_path)
            .map_err(DownloadError::Source)?;
        ctx.check_cancel()?;
        let expected = total_bytes(&files);

        let reusable = verified_reusable_bytes(&ctx.root, recipe, &files)?;
        // Capacity preflight has no measurable progress fraction.
        progress.stage("disk_preflight", None);
        disk_preflight(
            ctx.disk_free_bytes,
            expected.saturating_sub(reusable),
            ctx.disk_reserve_bytes,
        )?;
        let work_dir = work_dir(&ctx.root, recipe)?;
        ctx.check_cancel()?;

        // Commit manifest and downloading state atomically, then release the database guard before source or filesystem I/O.
        {
            let mut conn = database.lock();
            let transaction = conn
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(|error| DownloadError::Internal(error.to_string()))?;
            for file in &files {
                crate::store::upsert_model_file(&transaction, recipe.id(), file)
                    .map_err(|error| DownloadError::Internal(error.to_string()))?;
            }
            crate::store::mark_model_downloading(&transaction, recipe.id())
                .map_err(|error| DownloadError::Internal(error.to_string()))?;
            transaction
                .commit()
                .map_err(|error| DownloadError::Internal(error.to_string()))?;
        }

        // Resume progress from verified staged bytes and clear installed state on failure while retaining resumable data.
        if expected > 0 {
            progress.stage(
                "downloading",
                Some((reusable as f64 / expected as f64).clamp(0.0, 1.0)),
            );
        } else {
            progress.stage("downloading", None);
        }
        let staged = match stage_files_with_credential(
            recipe,
            &files,
            &*self.source,
            &work_dir,
            ctx,
            progress,
            credential_path,
        ) {
            Ok(staged) => staged,
            Err(error) => {
                return Err(reset_after_failure(database, recipe.id(), error));
            }
        };
        if let Err(error) = ctx.check_cancel() {
            return Err(reset_after_failure(database, recipe.id(), error));
        }

        // Materialization rehashes every file without a known-size progress denominator.
        progress.stage("materialising", None);
        if let Err(error) =
            materialise_snapshot(&staged, models_root, recipe.id(), &recipe.source.revision)
        {
            return Err(reset_after_failure(database, recipe.id(), error));
        }
        if let Err(error) = ctx.check_cancel() {
            return Err(reset_after_failure(database, recipe.id(), error));
        }

        // Record installation success only after verified blobs exist on disk.
        let installed = {
            let conn = database.lock();
            crate::store::mark_model_installed(&conn, recipe.id(), expected)
        };
        if let Err(error) = installed {
            return Err(reset_after_failure(
                database,
                recipe.id(),
                DownloadError::Internal(error.to_string()),
            ));
        }
        Ok(())
    }
}

fn reset_after_failure(
    database: &Mutex<Connection>,
    model_id: &str,
    original: DownloadError,
) -> DownloadError {
    match crate::store::mark_model_available(&database.lock(), model_id) {
        Ok(()) => original,
        Err(reset_error) => DownloadError::Internal(format!(
            "download failed ({original}); resetting model state failed: {reset_error}"
        )),
    }
}

fn work_dir(root: &Path, recipe: &ModelRecipe) -> Result<PathBuf> {
    crate::model_paths::validate_model_id(recipe.id()).map_err(DownloadError::Internal)?;
    crate::model_paths::validate_revision(&recipe.source.revision)
        .map_err(DownloadError::Internal)?;
    Ok(root.join(recipe.id()).join(&recipe.source.revision))
}

#[cfg(test)]
#[path = "download/total_bytes_tests.rs"]
mod total_bytes_tests;

#[cfg(test)]
#[path = "download/materialise_duplicate_tests.rs"]
mod materialise_duplicate_tests;

mod staging;
pub use staging::stage_files;
use staging::stage_files_with_credential;

mod snapshot;
use snapshot::{ensure_regular_file, sha256_regular_no_follow, sync_directory};
pub use snapshot::{materialise_snapshot, sha256_file};
