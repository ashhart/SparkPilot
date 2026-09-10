use super::*;
use crate::mount_pin::PinnedDirectory;

pub(super) struct ModelPolicy<'a> {
    pub(super) models_root: &'a Path,
    pub(super) plan_only: bool,
}

impl ModelPolicy<'_> {
    /// Check the snapshot's shape and, outside planning, open it through a no-follow walk; the path is the mount source name.
    pub(super) fn validate_model_snapshot(&self, raw: &str) -> Result<PathBuf, BackendError> {
        self.pin_model_snapshot(raw).map(|(path, _)| path)
    }

    /// Validate and keep the snapshot open so a swap between validation and the container mount is detected.
    pub(super) fn pin_model_snapshot(
        &self,
        raw: &str,
    ) -> Result<(PathBuf, Option<PinnedDirectory>), BackendError> {
        let path = PathBuf::from(raw);
        let snapshots_root = self.models_root.join("snapshots");
        if !path.is_absolute()
            || path.components().any(|component| {
                matches!(
                    component,
                    Component::ParentDir | Component::CurDir | Component::Prefix(_)
                )
            })
            || !path.starts_with(&snapshots_root)
        {
            return Err(BackendError::InvalidInput(
                "model snapshot must be beneath the configured snapshots root".into(),
            ));
        }
        // A mountable snapshot names a model revision, never the snapshots root or a bare model directory.
        let relative = path.strip_prefix(self.models_root).map_err(|_| {
            BackendError::InvalidInput("model snapshot is outside the models root".into())
        })?;
        if relative.components().count() < 3 {
            return Err(BackendError::InvalidInput(
                "model snapshot must name a model revision beneath the snapshots root".into(),
            ));
        }
        if self.plan_only {
            return Ok((path, None));
        }
        let pin = PinnedDirectory::open(self.models_root, relative).map_err(|error| {
            BackendError::InvalidInput(format!(
                "model snapshot is not a mountable directory: {error}"
            ))
        })?;
        Ok((pin.path(), Some(pin)))
    }
}
