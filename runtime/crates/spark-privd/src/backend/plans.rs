use super::*;
use crate::mount_pin::PinnedDirectory;

/// Validated container arguments exposed for policy inspection.
pub struct ContainerPlan {
    pub argv: Vec<String>,
    pub summary: serde_json::Value,
    pub(super) credential_path: PathBuf,
    /// Held open from validation until the mount is verified; planning alone opens nothing.
    pub(super) snapshot_pin: Option<PinnedDirectory>,
}

/// Validated project arguments with helper-controlled networking.
pub struct ProjectContainerPlan {
    pub argv: Vec<String>,
    pub summary: serde_json::Value,
    /// The workspace as validated; the launch re-verifies it against this after docker has mounted it.
    pub(super) workspace_pin: PinnedDirectory,
}

pub struct OpenWebUiContainerPlan {
    pub argv: Vec<String>,
    pub summary: serde_json::Value,
}

/// Refuse a launch whose mount source no longer resolves to the validated directory, removing what docker started.
pub(super) fn verify_mount_after_launch(
    docker_bin: &str,
    container_name: &str,
    what: &str,
    pin: &PinnedDirectory,
) -> Result<(), BackendError> {
    let Err(error) = pin.verify() else {
        return Ok(());
    };
    tracing::warn!(
        container = container_name,
        %error,
        "{what} changed between validation and the container mount; removing the container"
    );
    let removed = Command::new(docker_bin)
        .args(["rm", "--force", container_name])
        .output();
    let cleanup = match removed {
        Ok(output) if output.status.success() => "removed",
        _ => "could not be removed",
    };
    Err(BackendError::Failure(format!(
        "{what} was replaced during launch ({error}); the container {cleanup}"
    )))
}
