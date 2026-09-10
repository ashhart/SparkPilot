//! Cache only pinned public executables outside project mounts; copy verified bytes into each isolated workspace.
use base64::Engine as _;
use sha2::{Digest as _, Sha256, Sha512};
use std::{io::Read as _, path::Path, time::Duration};

const LIMIT: u64 = 512 * 1024 * 1024;
static CACHE_LOCK: parking_lot::Mutex<()> = parking_lot::Mutex::new(());
const LOCK: &str = include_str!("harness-locks/codex/package-lock.json");
type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

struct Package {
    url: String,
    integrity: Vec<u8>,
    triple: &'static str,
}
impl Package {
    fn pinned() -> Result<Self> {
        let (arch, triple) = match std::env::consts::ARCH {
            "aarch64" => ("arm64", "aarch64-unknown-linux-musl"),
            "x86_64" => ("x64", "x86_64-unknown-linux-musl"),
            _ => return Err("Codex is unavailable for this Spark architecture".into()),
        };
        let lock: serde_json::Value = serde_json::from_str(LOCK)?;
        let entry = &lock["packages"][format!("node_modules/@openai/codex-linux-{arch}")];
        let url = entry["resolved"]
            .as_str()
            .ok_or("Missing pinned Codex URL")?
            .to_owned();
        if !url.starts_with("https://registry.npmjs.org/@openai/codex/-/codex-") {
            return Err("Codex package source is not allowlisted".into());
        }
        let integrity = base64::engine::general_purpose::STANDARD.decode(
            entry["integrity"]
                .as_str()
                .and_then(|value| value.strip_prefix("sha512-"))
                .ok_or("Missing Codex SHA-512 pin")?,
        )?;
        Ok(Self {
            url,
            integrity,
            triple,
        })
    }
}

pub(super) fn prepare(data_dir: &Path, workspace: &Path) -> std::result::Result<String, String> {
    let result = (|| -> Result<String> {
        let package = Package::pinned()?;
        prepare_with(data_dir, workspace, &package, || {
            let client = reqwest::blocking::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .connect_timeout(Duration::from_secs(15))
                .timeout(Duration::from_secs(300))
                .build()?;
            let response = client.get(&package.url).send()?.error_for_status()?;
            let mut bytes = Vec::new();
            response.take(LIMIT + 1).read_to_end(&mut bytes)?;
            Ok(bytes)
        })
    })();
    result.map_err(|error| format!("Could not prepare Codex: {error}"))
}

fn prepare_with(
    data_dir: &Path,
    workspace: &Path,
    package: &Package,
    fetch: impl FnOnce() -> Result<Vec<u8>>,
) -> Result<String> {
    let _lock = CACHE_LOCK.lock();
    let key = hex::encode(&package.integrity);
    let cache = format!("harness-cache/codex-{key}");
    crate::beneath::create_dir_all_beneath(data_dir, &cache)?;
    let archive_path = format!("{cache}/package.tgz");
    let verified = |bytes: &[u8]| {
        bytes.len() as u64 <= LIMIT && Sha512::digest(bytes)[..] == package.integrity
    };
    let archive =
        match crate::beneath::read_beneath_bounded(data_dir, &archive_path, LIMIT as usize) {
            Ok(bytes) if verified(&bytes) => bytes,
            _ => {
                let bytes = fetch()?;
                if !verified(&bytes) {
                    return Err("Codex package integrity check failed".into());
                }
                crate::beneath::write_beneath(data_dir, &archive_path, &bytes)?;
                bytes
            }
        };
    // No package scripts run and no project file is ever promoted into the shared cache.
    let binaries = extract(&archive, package.triple)?;
    let directory = format!(".spark-codex-{}", &key[..16]);
    crate::beneath::create_dir_all_beneath(workspace, &directory)?;
    for (name, bytes) in binaries {
        let relative = format!("{directory}/{name}");
        if let Some(parent) = Path::new(&relative).parent() {
            crate::beneath::create_dir_all_beneath(
                workspace,
                parent.to_str().ok_or("Invalid Codex path")?,
            )?;
        }
        let unchanged = crate::beneath::read_beneath_bounded(workspace, &relative, LIMIT as usize)
            .is_ok_and(|existing| Sha256::digest(&existing) == Sha256::digest(&bytes));
        use std::os::unix::fs::PermissionsExt as _;
        let executable = crate::beneath::metadata_beneath(workspace, &relative)
            .is_ok_and(|metadata| metadata.permissions().mode() & 0o700 == 0o700);
        if !unchanged || !executable {
            crate::beneath::write_executable_beneath(workspace, &relative, &bytes)?;
        }
    }
    Ok(directory)
}

fn extract(bytes: &[u8], triple: &str) -> Result<Vec<(&'static str, Vec<u8>)>> {
    let wanted: Vec<_> = [
        "bin/codex",
        "bin/codex-code-mode-host",
        "codex-path/rg",
        "codex-resources/bwrap",
        "codex-resources/zsh/bin/zsh",
        "codex-package.json",
    ]
    .into_iter()
    .map(|name| (format!("package/vendor/{triple}/{name}"), name))
    .collect();
    let decoder = flate2::read::GzDecoder::new(bytes).take(LIMIT + 1);
    let mut archive = tar::Archive::new(decoder);
    let mut result = Vec::new();
    for entry in archive.entries()? {
        let mut entry = entry?;
        let path = entry.path()?;
        let Some((_, name)) = wanted.iter().find(|(wanted, _)| path == Path::new(wanted)) else {
            continue;
        };
        if !entry.header().entry_type().is_file()
            || entry.size() > LIMIT
            || result.iter().any(|(existing, _)| existing == name)
        {
            return Err("Codex archive contains an invalid executable".into());
        }
        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes)?;
        if bytes.is_empty() {
            return Err("Codex executable is empty".into());
        }
        result.push((*name, bytes));
    }
    if result.len() != wanted.len() {
        return Err("Codex archive is missing Codex or ripgrep".into());
    }
    Ok(result)
}

#[cfg(test)]
mod tests;
