use super::*;

pub(super) struct EngineCredentials<'a> {
    pub(super) runtime_dir: &'a Path,
}

impl EngineCredentials<'_> {
    pub(super) fn write_api_credential(
        &self,
        path: &Path,
        api_key: &str,
    ) -> Result<CredentialGuard, BackendError> {
        let parent = path
            .parent()
            .ok_or_else(|| BackendError::InvalidInput("credential path has no parent".into()))?;
        fs::create_dir_all(parent)?;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)?;
        file.write_all(b"VLLM_API_KEY=")?;
        file.write_all(api_key.as_bytes())?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        Ok(CredentialGuard(path.to_owned()))
    }

    /// Delete stale env files after Docker has copied credentials into its container configuration.
    pub(super) fn cleanup_stale_credentials(&self) -> Result<(), BackendError> {
        let directory = self.runtime_dir.join("credentials");
        if !directory.exists() {
            return Ok(());
        }
        for entry in fs::read_dir(&directory)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with("spark-vllm-") && name.ends_with(".env") {
                fs::remove_file(entry.path())?;
            }
        }
        Ok(())
    }

    pub(super) fn remove_instance_credential(&self, instance_id: &uuid::Uuid) {
        let path = self
            .runtime_dir
            .join("credentials")
            .join(format!("spark-vllm-{instance_id}.env"));
        let _ = fs::remove_file(path);
    }
}
