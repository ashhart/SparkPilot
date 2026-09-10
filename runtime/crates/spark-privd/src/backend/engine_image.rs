use super::*;

pub(super) struct EngineImage<'a> {
    pub(super) docker_bin: &'a String,
}

impl EngineImage<'_> {
    pub(super) fn image_is_present(&self, image_digest: &str) -> Result<bool, BackendError> {
        let status = Command::new(self.docker_bin)
            .args(["image", "inspect", image_digest])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        Ok(status.success())
    }

    pub(super) fn pull_image(&self, image_digest: &str) -> Result<(), BackendError> {
        let mut child = Command::new(self.docker_bin)
            .args(["pull", "--quiet", image_digest])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        let deadline = Instant::now() + DockerBackend::IMAGE_PULL_TIMEOUT;
        loop {
            if let Some(status) = child.try_wait()? {
                if status.success() {
                    return Ok(());
                }
                return Err(BackendError::Failure(
                    "digest-pinned engine image pull failed; check registry access and storage"
                        .into(),
                ));
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                return Err(BackendError::Failure(
                    "digest-pinned engine image pull exceeded 30 minutes".into(),
                ));
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    }
}
