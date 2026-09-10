use super::*;

pub(super) struct DockerInspection<'a> {
    pub(super) docker_bin: &'a str,
    pub(super) plan_only: bool,
    pub(super) runner: &'a dyn CommandRunner,
}

impl DockerInspection<'_> {
    pub(super) fn webui_command(&self, args: &[&str]) -> Result<Vec<u8>, BackendError> {
        let output = crate::backend::command::run(
            self.plan_only,
            self.runner,
            self.docker_bin,
            args.iter().map(|arg| (*arg).into()).collect(),
            None,
        )?;
        if !output.success() {
            return Err(BackendError::Failure(
                "Open WebUI container command failed; existing ownership evidence was retained"
                    .into(),
            ));
        }
        Ok(output.stdout)
    }

    pub(super) fn webui_inspect(
        &self,
        kind: &str,
        id: &str,
    ) -> Result<Option<Value>, BackendError> {
        let output = crate::backend::command::run(
            self.plan_only,
            self.runner,
            self.docker_bin,
            vec![kind.into(), "inspect".into(), id.into()],
            None,
        )?;
        if !output.success() {
            let error = String::from_utf8_lossy(&output.stderr).to_ascii_lowercase();
            if error.contains("no such object")
                || error.contains("no such container")
                || error.contains("no such volume")
            {
                return Ok(None);
            }
            return Err(BackendError::Failure(
                "Open WebUI ownership inspection is unavailable".into(),
            ));
        }
        let mut values: Vec<Value> =
            serde_json::from_slice(&output.stdout).map_err(|_| ownership_error())?;
        if values.len() != 1 {
            return Err(ownership_error());
        }
        Ok(values.remove(0).into())
    }

    pub(super) fn webui_verify_container(
        &self,
        container: &Container,
    ) -> Result<Option<Value>, BackendError> {
        let Some(value) = self.webui_inspect("container", &container.id)? else {
            return Ok(None);
        };
        if value["Id"] != container.id
            || value["Config"]["Image"] != container.image
            || hash(&configuration(&value)) != container.configuration_sha256
        {
            return Err(ownership_error());
        }
        Ok(Some(value))
    }

    pub(super) fn webui_verify_volume(&self, volume: &Volume) -> Result<(), BackendError> {
        let value = self
            .webui_inspect("volume", &volume.name)?
            .ok_or_else(ownership_error)?;
        let metadata = fs::symlink_metadata(&volume.mountpoint).map_err(|_| ownership_error())?;
        if hash(&value) != volume.inspection_sha256
            || !metadata.is_dir()
            || metadata.file_type().is_symlink()
            || metadata.dev() != volume.device
            || metadata.ino() != volume.inode
        {
            return Err(ownership_error());
        }
        Ok(())
    }

    pub(super) fn webui_verify(&self, journal: Option<&Journal>) -> Result<(), BackendError> {
        // Names are only collision checks; they confer no authority.
        for name in [OPEN_WEBUI_CONTAINER, OPEN_WEBUI_BOOTSTRAP_CONTAINER] {
            if let Some(value) = self.webui_inspect("container", name)? {
                let id = value["Id"].as_str().ok_or_else(ownership_error)?;
                if !journal.is_some_and(|journal| {
                    journal
                        .current
                        .iter()
                        .chain(journal.previous.iter())
                        .any(|item| item.id == id)
                }) {
                    return Err(ownership_error());
                }
            }
        }
        if let Some(journal) = journal {
            if let Some(volume) = &journal.volume
                && !(journal.phase == Phase::Removing
                    && journal.erase_data
                    && self.webui_inspect("volume", &volume.name)?.is_none())
            {
                self.webui_verify_volume(volume)?;
            }
            for container in journal.current.iter().chain(journal.previous.iter()) {
                self.webui_verify_container(container)?;
            }
        } else if self
            .webui_inspect("volume", OPEN_WEBUI_DATA_VOLUME)?
            .is_some()
        {
            return Err(ownership_error());
        }
        Ok(())
    }

    pub(super) fn webui_remove_exact(&self, container: &Container) -> Result<(), BackendError> {
        if self.webui_verify_container(container)?.is_some() {
            self.webui_command(&["rm", "--force", &container.id])?;
        }
        Ok(())
    }
}

impl DockerInspection<'_> {
    pub(super) fn wait_until_ready(
        &self,
        container: &Container,
        healthy: impl Fn() -> bool,
    ) -> Result<bool, BackendError> {
        let deadline = Instant::now() + Duration::from_secs(120);
        while Instant::now() < deadline {
            let value = self
                .webui_verify_container(container)?
                .ok_or_else(ownership_error)?;
            if value["State"]["Running"] != true {
                return Ok(false);
            }
            if healthy() {
                return Ok(true);
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        Ok(false)
    }
}
