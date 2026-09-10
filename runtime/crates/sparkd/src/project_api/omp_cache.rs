//! Cache the pinned Oh My Pi release on the host once and seed every workspace from it, so a first session never waits on GitHub.
use sha2::{Digest as _, Sha256};
use std::{io::Read as _, path::Path, time::Duration};

const LIMIT: u64 = 256 * 1024 * 1024;
static CACHE_LOCK: parking_lot::Mutex<()> = parking_lot::Mutex::new(());
const LOCK: &str = include_str!("harness-locks/oh_my_pi/release.json");
type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

pub(crate) struct Release {
    pub(crate) version: String,
    url: String,
    digest: Vec<u8>,
}

impl Release {
    pub(crate) fn pinned() -> Result<Self> {
        let arch = match std::env::consts::ARCH {
            "aarch64" => "arm64",
            "x86_64" => "x64",
            _ => return Err("Oh My Pi is unavailable for this Spark architecture".into()),
        };
        let lock: serde_json::Value = serde_json::from_str(LOCK)?;
        let version = lock["version"]
            .as_str()
            .ok_or("Missing pinned Oh My Pi version")?;
        if version.is_empty()
            || !version
                .chars()
                .all(|character| character.is_ascii_digit() || character == '.')
        {
            return Err("Invalid pinned Oh My Pi version".into());
        }
        let digest = hex::decode(
            lock["sha256"][arch]
                .as_str()
                .ok_or("Missing Oh My Pi SHA-256 pin")?,
        )?;
        if digest.len() != 32 {
            return Err("Invalid Oh My Pi SHA-256 pin".into());
        }
        Ok(Self {
            version: version.to_owned(),
            url: format!(
                "https://github.com/can1357/oh-my-pi/releases/download/v{version}/omp-linux-{arch}"
            ),
            digest,
        })
    }

    fn cache_directory(&self) -> String {
        format!("harness-cache/omp-{}", hex::encode(&self.digest))
    }

    fn cache_path(&self) -> String {
        format!("{}/omp", self.cache_directory())
    }

    /// The path the launcher verifies against its own pin before it would download anything.
    pub(crate) fn workspace_path(&self) -> String {
        format!(".spark-home/tools/omp-{}", self.version)
    }

    fn verified(&self, bytes: &[u8]) -> bool {
        bytes.len() as u64 <= LIMIT && Sha256::digest(bytes)[..] == self.digest[..]
    }
}

fn cached(data_dir: &Path, release: &Release) -> Option<Vec<u8>> {
    crate::beneath::read_beneath_bounded(data_dir, &release.cache_path(), LIMIT as usize)
        .ok()
        .filter(|bytes| release.verified(bytes))
}

/// Whether the pinned release is already cached and intact.
pub(crate) fn is_cached(data_dir: &Path) -> bool {
    Release::pinned().is_ok_and(|release| cached(data_dir, &release).is_some())
}

/// Download the pinned release once; the result says whether a download happened.
pub(crate) fn warm(data_dir: &Path) -> std::result::Result<bool, String> {
    let result = (|| -> Result<bool> {
        let release = Release::pinned()?;
        warm_with(data_dir, &release, || fetch(&release.url))
    })();
    result.map_err(|error| format!("Could not cache Oh My Pi: {error}"))
}

fn fetch(url: &str) -> Result<Vec<u8>> {
    // GitHub answers a release download with a redirect to its asset host; nothing else is followed.
    let policy = reqwest::redirect::Policy::custom(|attempt| {
        let allowed = attempt.url().scheme() == "https"
            && attempt.url().host_str().is_some_and(|host| {
                matches!(
                    host,
                    "github.com"
                        | "objects.githubusercontent.com"
                        | "release-assets.githubusercontent.com"
                )
            });
        if attempt.previous().len() > 3 || !allowed {
            attempt.stop()
        } else {
            attempt.follow()
        }
    });
    let client = reqwest::blocking::Client::builder()
        .redirect(policy)
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(600))
        .build()?;
    let response = client.get(url).send()?.error_for_status()?;
    let mut bytes = Vec::new();
    response.take(LIMIT + 1).read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn warm_with(
    data_dir: &Path,
    release: &Release,
    fetch: impl FnOnce() -> Result<Vec<u8>>,
) -> Result<bool> {
    let _lock = CACHE_LOCK.lock();
    if cached(data_dir, release).is_some() {
        return Ok(false);
    }
    let bytes = fetch()?;
    if !release.verified(&bytes) {
        return Err("Oh My Pi download verification failed".into());
    }
    crate::beneath::create_dir_all_beneath(data_dir, &release.cache_directory())?;
    crate::beneath::write_beneath(data_dir, &release.cache_path(), &bytes)?;
    Ok(true)
}

/// Copy the cached release into one workspace; the result says whether the workspace now holds it.
pub(crate) fn seed_workspace(
    data_dir: &Path,
    workspace: &Path,
) -> std::result::Result<bool, String> {
    let result = (|| -> Result<bool> {
        let release = Release::pinned()?;
        seed_with(data_dir, workspace, &release)
    })();
    result.map_err(|error| format!("Could not seed Oh My Pi: {error}"))
}

fn seed_with(data_dir: &Path, workspace: &Path, release: &Release) -> Result<bool> {
    let _lock = CACHE_LOCK.lock();
    let Some(bytes) = cached(data_dir, release) else {
        return Ok(false);
    };
    let relative = release.workspace_path();
    let unchanged = crate::beneath::read_beneath_bounded(workspace, &relative, LIMIT as usize)
        .is_ok_and(|existing| release.verified(&existing));
    use std::os::unix::fs::PermissionsExt as _;
    let executable = crate::beneath::metadata_beneath(workspace, &relative)
        .is_ok_and(|metadata| metadata.permissions().mode() & 0o700 == 0o700);
    if unchanged && executable {
        return Ok(true);
    }
    crate::beneath::create_dir_all_beneath(workspace, ".spark-home/tools")?;
    crate::beneath::write_executable_beneath(workspace, &relative, &bytes)?;
    Ok(true)
}

#[cfg(test)]
mod tests;
