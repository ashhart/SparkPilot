use super::*;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Container {
    pub(super) id: String,
    pub(super) image: String,
    pub(super) configuration_sha256: String,
    pub(super) bootstrap: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Volume {
    pub(super) name: String,
    pub(super) inspection_sha256: String,
    pub(super) mountpoint: PathBuf,
    pub(super) device: u64,
    pub(super) inode: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Phase {
    Installing,
    Ready,
    Updating,
    Promoting,
    Removing,
    Removed,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Journal {
    pub(super) version: u32,
    #[serde(default = "crate::protocol::default_open_webui_port")]
    pub(super) port: u16,
    #[serde(default)]
    pub(super) adopted: bool,
    pub(super) generation: uuid::Uuid,
    pub(super) phase: Phase,
    // A matching name and labels cannot replace a missing persisted create receipt.
    pub(super) pending_create: bool,
    pub(super) volume: Option<Volume>,
    pub(super) current: Option<Container>,
    pub(super) previous: Option<Container>,
    pub(super) last_repair_epoch: u64,
    pub(super) erase_data: bool,
}

pub(super) fn hash(value: &Value) -> String {
    hex::encode(Sha256::digest(
        serde_json::to_vec(value).expect("JSON value"),
    ))
}

pub(super) fn valid_id(id: &str) -> bool {
    id.len() == 64 && id.bytes().all(|b| b.is_ascii_hexdigit())
}

pub(super) fn configuration(value: &Value) -> Value {
    // Bind process, privilege, limits and mounts; exclude mutable name and lifecycle state.
    json!({"Image":value["Image"],"Config":value["Config"],"HostConfig":value["HostConfig"],"Mounts":value["Mounts"]})
}

pub(super) fn private_metadata(path: &Path, directory: bool) -> Result<fs::Metadata, BackendError> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.file_type().is_symlink()
        || if directory {
            !metadata.is_dir()
        } else {
            !metadata.is_file()
        }
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
        || (!directory && metadata.nlink() != 1)
    {
        return Err(ownership_error());
    }
    Ok(metadata)
}
