use super::*;

pub(super) fn directory_size(root: &Path) -> u64 {
    let mut total = 0_u64;
    let mut pending = vec![root.to_path_buf()];
    while let Some(path) = pending.pop() {
        let Ok(metadata) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_file() {
            total = total.saturating_add(metadata.len());
            continue;
        }
        let Ok(entries) = std::fs::read_dir(path) else {
            continue;
        };
        pending.extend(entries.filter_map(Result::ok).map(|entry| entry.path()));
    }
    total
}

pub(super) fn partial_download_size(root: &Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(root) else {
        return 0;
    };
    entries
        .filter_map(Result::ok)
        .filter(|entry| {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            name.ends_with(".partial") || name.ends_with(".part")
        })
        .filter_map(|entry| entry.metadata().ok())
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len())
        .sum()
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StorageCleanupRequest {
    partial_downloads: bool,
    unused_blobs: bool,
    stopped_containers: bool,
    unused_images: bool,
}

pub async fn clean_storage(
    State(state): State<AppState>,
    Extension(principal): Extension<Principal>,
    Extension(authenticated): Extension<AuthenticatedRequest>,
    idempotency: IdempotencyRequest,
    headers: HeaderMap,
    Json(request): Json<StorageCleanupRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    if !request.partial_downloads
        && !request.unused_blobs
        && !request.stopped_containers
        && !request.unused_images
    {
        return Err(error_envelope(
            StatusCode::BAD_REQUEST,
            "NO_CLEANUP_SELECTED",
            "select at least one storage class",
        ));
    }
    let privileged = state.privileged.clone();
    if (request.stopped_containers || request.unused_images) && privileged.is_none() {
        return Err(error_envelope(
            StatusCode::SERVICE_UNAVAILABLE,
            "STORAGE_SERVICE_UNAVAILABLE",
            "container cleanup is unavailable",
        ));
    }
    let downloads = state.storage.downloads.clone();
    let blobs = state.config.data_dir.join("blobs");
    let partial_downloads = request.partial_downloads;
    let unused_blobs = request.unused_blobs;
    let stopped_containers = request.stopped_containers;
    let unused_images = request.unused_images;
    enqueue_operation(
        state,
        principal,
        authenticated,
        idempotency,
        headers,
        "/api/v1/storage/cleanup",
        "storage.cleanup",
        json!({
            "partial_downloads": partial_downloads,
            "unused_blobs": unused_blobs,
            "stopped_containers": stopped_containers,
            "unused_images": unused_images,
        }),
        None,
        move |operation_id, lease| {
            let mut reclaimed = 0_u64;
            if partial_downloads {
                reclaimed = reclaimed.saturating_add(remove_partial_downloads(&downloads));
            }
            if unused_blobs {
                reclaimed = reclaimed.saturating_add(remove_unlinked_blobs(&blobs));
            }
            if stopped_containers || unused_images {
                let result = privileged.expect("validated privileged client").call(
                    PrivilegedOperation::PruneContainerStorage {
                        request_id: operation_id,
                        stopped_containers,
                        unused_images,
                    },
                );
                match result {
                    Ok(response) if response.accepted => {}
                    Ok(response) => {
                        lease.settle_failed(&response.code);
                        return;
                    }
                    Err(error) => {
                        tracing::error!(%error, "container storage cleanup failed");
                        lease.settle_failed("CONTAINER_STORAGE_CLEANUP_FAILED");
                        return;
                    }
                }
            }
            lease.settle_succeeded(&json!({ "reclaimed_bytes": reclaimed }));
        },
    )
    .await
}

pub(super) fn remove_partial_downloads(root: &Path) -> u64 {
    remove_matching_files(root, |name, _| {
        name.ends_with(".part") || name.ends_with(".partial")
    })
}

pub(super) fn remove_unlinked_blobs(root: &Path) -> u64 {
    use std::os::unix::fs::MetadataExt;
    remove_matching_files(root, |_, metadata| metadata.nlink() == 1)
}

pub(super) fn remove_matching_files(
    root: &Path,
    predicate: impl Fn(&str, &std::fs::Metadata) -> bool,
) -> u64 {
    let mut reclaimed = 0_u64;
    let mut pending = vec![PathBuf::from(root)];
    while let Some(path) = pending.pop() {
        let Ok(metadata) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            if let Ok(entries) = std::fs::read_dir(path) {
                pending.extend(entries.filter_map(Result::ok).map(|entry| entry.path()));
            }
            continue;
        }
        if !metadata.is_file() {
            continue;
        }
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("");
        if predicate(name, &metadata) && std::fs::remove_file(&path).is_ok() {
            reclaimed = reclaimed.saturating_add(metadata.len());
        }
    }
    reclaimed
}
