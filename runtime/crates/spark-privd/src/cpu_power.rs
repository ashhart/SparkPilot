//! Reversible CPU ceilings from Linux cpufreq policies; never change governors or exceed a saved ceiling.
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::Path,
};

pub const POLICY_ROOT: &str = "/sys/devices/system/cpu/cpufreq";
pub const STATE_PATH: &str = "/var/lib/spark-privd/cpu-power.json";
pub const AUTOMATIC: u8 = 200;
pub const COOLER: u8 = 201;
pub const QUIET: u8 = 202;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Policy {
    pub name: String,
    pub minimum_khz: u64,
    pub maximum_khz: u64,
    pub ceiling_khz: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Saved {
    version: u8,
    mode: u8,
    baseline: Vec<Policy>,
}

fn number(path: &Path) -> Result<u64, String> {
    let value: u64 = fs::read_to_string(path)
        .map_err(|_| "CPU frequency information is unavailable")?
        .trim()
        .parse()
        .map_err(|_| "CPU frequency information is invalid")?;
    if value == 0 || value > 10_000_000 {
        return Err("CPU frequency is outside supported bounds".into());
    }
    Ok(value)
}

fn valid_name(name: &str) -> bool {
    name.strip_prefix("policy").is_some_and(|suffix| {
        !suffix.is_empty() && suffix.len() <= 5 && suffix.bytes().all(|byte| byte.is_ascii_digit())
    })
}

pub fn policies(root: &Path) -> Result<Vec<Policy>, String> {
    let entries = fs::read_dir(root).map_err(|_| "CPU frequency controls are unavailable")?;
    let mut result = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|_| "CPU policies could not be read")?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !valid_name(&name) {
            continue;
        }
        let meta =
            fs::symlink_metadata(entry.path()).map_err(|_| "CPU policy metadata is unavailable")?;
        if !meta.is_dir() || meta.file_type().is_symlink() {
            return Err("Unexpected CPU policy path".into());
        }
        let minimum_khz = number(&entry.path().join("cpuinfo_min_freq"))?;
        let maximum_khz = number(&entry.path().join("cpuinfo_max_freq"))?;
        let ceiling_khz = number(&entry.path().join("scaling_max_freq"))?;
        if minimum_khz > ceiling_khz || ceiling_khz > maximum_khz {
            return Err("CPU limits are inconsistent".into());
        }
        result.push(Policy {
            name,
            minimum_khz,
            maximum_khz,
            ceiling_khz,
        });
        if result.len() > 256 {
            return Err("Too many CPU policies".into());
        }
    }
    if result.is_empty() {
        return Err("CPU frequency controls are unavailable".into());
    }
    result.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(result)
}

fn read_saved(path: &Path) -> Result<Option<Saved>, String> {
    let file = match fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("Saved CPU settings could not be read".into()),
    };
    if !file
        .metadata()
        .map_err(|_| "Saved CPU settings are unavailable")?
        .is_file()
    {
        return Err("Invalid CPU settings file".into());
    }
    let mut bytes = Vec::new();
    file.take(65537)
        .read_to_end(&mut bytes)
        .map_err(|_| "Saved CPU settings could not be read")?;
    if bytes.len() > 65536 {
        return Err("Saved CPU settings are too large".into());
    }
    let saved: Saved =
        serde_json::from_slice(&bytes).map_err(|_| "Saved CPU settings are invalid")?;
    if saved.version != 1
        || ![AUTOMATIC, COOLER, QUIET].contains(&saved.mode)
        || saved.baseline.is_empty()
        || saved.baseline.len() > 256
        || saved.baseline.iter().any(|p| {
            !valid_name(&p.name)
                || p.minimum_khz == 0
                || p.minimum_khz > p.ceiling_khz
                || p.ceiling_khz > p.maximum_khz
                || p.maximum_khz > 10_000_000
        })
    {
        return Err("Saved CPU settings are invalid".into());
    }
    Ok(Some(saved))
}

fn write_saved(path: &Path, saved: &Saved) -> Result<(), String> {
    let parent = path.parent().ok_or("Missing CPU settings directory")?;
    fs::create_dir_all(parent).map_err(|_| "CPU settings directory could not be created")?;
    let temp = parent.join(format!("cpu-power-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&temp)
            .map_err(|_| "CPU settings could not be saved")?;
        file.write_all(
            &serde_json::to_vec(saved).map_err(|_| "CPU settings could not be encoded")?,
        )
        .and_then(|_| file.sync_all())
        .map_err(|_| "CPU settings could not be saved")?;
        fs::rename(&temp, path).map_err(|_| "CPU settings could not be saved")?;
        fs::File::open(parent)
            .and_then(|file| file.sync_all())
            .map_err(|_| "CPU settings could not be saved")?;
        Ok(())
    })();
    let _ = fs::remove_file(temp);
    result
}

fn ceiling(policy: &Policy, mode: u8) -> u64 {
    let percent = match mode {
        COOLER => 75,
        QUIET => 50,
        _ => 100,
    };
    (policy.ceiling_khz * percent / 100).max(policy.minimum_khz)
}

fn write_ceiling(root: &Path, policy: &Policy, khz: u64) -> Result<(), String> {
    let path = root.join(&policy.name).join("scaling_max_freq");
    let mut file = fs::OpenOptions::new()
        .write(true)
        .truncate(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)
        .map_err(|_| "The CPU frequency ceiling could not be changed")?;
    write!(file, "{khz}").map_err(|_| "The CPU frequency ceiling could not be changed")?;
    if number(&path)? > khz {
        return Err("The CPU driver did not accept the requested ceiling".into());
    }
    Ok(())
}

fn rollback(root: &Path, before: &[Policy], failure: String) -> String {
    let restored = before.iter().fold(true, |restored, original| {
        write_ceiling(root, original, original.ceiling_khz).is_ok() && restored
    });
    if restored {
        failure
    } else {
        format!(
            "{failure}. Some CPU limits could not be restored; check the Spark's power settings before trying again"
        )
    }
}

/// Serialized by the helper backend; a partially applied request rolls back every touched policy.
pub fn apply(root: &Path, state_path: &Path, mode: u8) -> Result<Vec<Policy>, String> {
    static CHANGE: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _change = CHANGE
        .lock()
        .map_err(|_| "CPU settings need a service restart")?;
    if ![AUTOMATIC, COOLER, QUIET].contains(&mode) {
        return Err("Unsupported CPU cooling setting".into());
    }
    let before = policies(root)?;
    let previous = read_saved(state_path)?;
    let baseline = previous
        .as_ref()
        .map(|saved| saved.baseline.clone())
        .unwrap_or_else(|| before.clone());
    if baseline.len() != before.len()
        || baseline.iter().zip(&before).any(|(saved, live)| {
            saved.name != live.name
                || saved.minimum_khz != live.minimum_khz
                || saved.maximum_khz != live.maximum_khz
        })
    {
        return Err("CPU hardware changed; saved limits need a new review".into());
    }
    // Check configured minima before any write; preserve the administrator's minima and governors.
    for policy in &baseline {
        let minimum = number(&root.join(&policy.name).join("scaling_min_freq"))?;
        if ceiling(policy, mode) < minimum {
            return Err("An existing minimum CPU frequency prevents this cooling setting; lower that minimum on the Spark first".into());
        }
    }
    // Persist the original ceilings before the first write, so even a crash can be restored.
    if previous.is_none() {
        write_saved(
            state_path,
            &Saved {
                version: 1,
                mode: AUTOMATIC,
                baseline: baseline.clone(),
            },
        )?;
    }
    for (index, policy) in baseline.iter().enumerate() {
        if let Err(error) = write_ceiling(root, policy, ceiling(policy, mode)) {
            return Err(rollback(root, &before[..=index], error));
        }
    }
    if let Err(error) = write_saved(
        state_path,
        &Saved {
            version: 1,
            mode,
            baseline,
        },
    ) {
        return Err(rollback(root, &before, error));
    }
    policies(root)
}

/// Infer the observed mode without reading the root-only journal in the unprivileged daemon.
pub fn observed_mode(policies: &[Policy]) -> Option<u8> {
    if policies.is_empty() {
        return None;
    }
    [AUTOMATIC, COOLER, QUIET].into_iter().find(|&mode| {
        policies.iter().all(|p| {
            let reference = Policy {
                ceiling_khz: p.maximum_khz,
                ..p.clone()
            };
            p.ceiling_khz.abs_diff(ceiling(&reference, mode)) <= 1000
        })
    })
}

pub fn restore_after_boot() -> Result<(), String> {
    let path = Path::new(STATE_PATH);
    let Some(saved) = read_saved(path)? else {
        return Ok(());
    };
    apply(Path::new(POLICY_ROOT), path, saved.mode).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("cpufreq");
        for (name, maximum) in [("policy0", 3_900_000), ("policy1", 2_800_000)] {
            let policy = root.join(name);
            fs::create_dir_all(&policy).unwrap();
            fs::write(policy.join("cpuinfo_min_freq"), "400000").unwrap();
            fs::write(policy.join("cpuinfo_max_freq"), maximum.to_string()).unwrap();
            fs::write(policy.join("scaling_max_freq"), maximum.to_string()).unwrap();
            fs::write(policy.join("scaling_min_freq"), "400000").unwrap();
            fs::write(policy.join("scaling_governor"), "schedutil").unwrap();
        }
        let state = dir.path().join("state/cpu-power.json");
        (dir, root, state)
    }
    #[test]
    fn both_cpu_types_are_capped_and_original_limits_restore_without_changing_governors() {
        let (_dir, root, state) = fixture();
        let original = policies(&root).unwrap();
        let cool = apply(&root, &state, COOLER).unwrap();
        assert_eq!(cool[0].ceiling_khz, 2_925_000);
        assert_eq!(cool[1].ceiling_khz, 2_100_000);
        assert_eq!(observed_mode(&cool), Some(COOLER));
        let quiet = apply(&root, &state, QUIET).unwrap();
        assert_eq!(quiet[0].ceiling_khz, 1_950_000);
        assert_eq!(quiet[1].ceiling_khz, 1_400_000);
        assert_eq!(apply(&root, &state, AUTOMATIC).unwrap(), original);
        assert_eq!(
            fs::read_to_string(root.join("policy0/scaling_governor")).unwrap(),
            "schedutil"
        );
    }
    #[test]
    fn a_custom_original_ceiling_is_preserved_and_hardware_changes_are_refused() {
        let (_dir, root, state) = fixture();
        fs::write(root.join("policy0/scaling_max_freq"), "3200000").unwrap();
        let original = policies(&root).unwrap();
        apply(&root, &state, COOLER).unwrap();
        assert_eq!(apply(&root, &state, AUTOMATIC).unwrap(), original);
        fs::write(root.join("policy0/cpuinfo_max_freq"), "4000000").unwrap();
        assert!(apply(&root, &state, QUIET).is_err());
    }
    #[test]
    fn invalid_modes_and_symlinked_writes_cannot_change_other_files() {
        let (dir, root, state) = fixture();
        assert!(apply(&root, &state, 203).is_err());
        let protected = dir.path().join("protected");
        fs::write(&protected, "3900000").unwrap();
        fs::remove_file(root.join("policy0/scaling_max_freq")).unwrap();
        std::os::unix::fs::symlink(&protected, root.join("policy0/scaling_max_freq")).unwrap();
        assert!(apply(&root, &state, QUIET).is_err());
        assert_eq!(fs::read_to_string(protected).unwrap(), "3900000");
    }

    #[test]
    fn a_configured_minimum_is_respected_before_any_cpu_is_changed() {
        let (_dir, root, state) = fixture();
        let before = policies(&root).unwrap();
        fs::write(root.join("policy1/scaling_min_freq"), "2000000").unwrap();
        assert!(
            apply(&root, &state, QUIET)
                .unwrap_err()
                .contains("minimum CPU frequency")
        );
        assert_eq!(policies(&root).unwrap(), before);
        assert!(!state.exists());
    }
}
