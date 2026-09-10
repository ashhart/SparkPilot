use super::*;

pub(super) struct VolumeProvisioner<'a> {
    pub(super) journal: journal::OwnedJournal<'a>,
    pub(super) docker: inspection::DockerInspection<'a>,
}

impl VolumeProvisioner<'_> {
    pub(super) fn webui_create_volume(&self, journal: &mut Journal) -> Result<(), BackendError> {
        let name = format!("spark-open-webui-data-{}", journal.generation);
        if self.docker.webui_inspect("volume", &name)?.is_some() {
            return Err(ownership_error());
        }
        journal.pending_create = true;
        self.journal.webui_save(journal)?;
        self.docker.webui_command(&[
            "volume",
            "create",
            "--driver=local",
            "--label",
            &format!("spark.ownership={}", journal.generation),
            &name,
        ])?;
        let value = self
            .docker
            .webui_inspect("volume", &name)?
            .ok_or_else(ownership_error)?;
        if value["Name"] != name
            || value["Driver"] != "local"
            || value["Labels"]["spark.ownership"] != journal.generation.to_string()
            || !(value["Options"].is_null() || value["Options"] == json!({}))
        {
            return Err(ownership_error());
        }
        let mountpoint = PathBuf::from(value["Mountpoint"].as_str().ok_or_else(ownership_error)?);
        let metadata = fs::symlink_metadata(&mountpoint)?;
        if !metadata.is_dir() || metadata.file_type().is_symlink() {
            return Err(ownership_error());
        }
        journal.volume = Some(Volume {
            name,
            inspection_sha256: hash(&value),
            mountpoint,
            device: metadata.dev(),
            inode: metadata.ino(),
        });
        journal.pending_create = false;
        self.journal.webui_save(journal)
    }
}
