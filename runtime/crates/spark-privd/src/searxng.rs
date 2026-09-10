//! Pin the Spark's own search service to one packaged release; callers choose nothing about how it runs.

/// searxng/searxng:2026.9.4-15b0c8ef3, resolved to its digest so a moved tag cannot change what runs.
pub const IMAGE: &str = "docker.io/searxng/searxng@sha256:8bb6a6f677a758cefa4ae2c9f5da1012876e428a4388e3e86f34be4ca715330a";
pub const REVISION: &str = "2026.9.4-15b0c8ef3";
pub const CONTAINER: &str = "spark-searxng";
pub const PORT: u16 = 18119;
/// The root-owned settings the helper writes; the container may only read it.
pub const SETTINGS_DIRECTORY: &str = "/var/lib/spark/searxng";
pub const SETTINGS_PATH: &str = "/var/lib/spark/searxng/settings.yml";
pub const MEMORY_BYTES: u64 = 1024 * 1024 * 1024;

/// The whole configuration, written by the helper so no default file is ever generated inside the container.
pub fn settings_file(secret: &str) -> String {
    format!(
        "# Written by spark-privd. Do not edit; it is replaced on every install.\n\
use_default_settings: true\n\
general:\n  debug: false\n  instance_name: \"Spark\"\n  enable_metrics: false\n  donation_url: false\n  contact_url: false\n\
server:\n  secret_key: \"{secret}\"\n  bind_address: \"0.0.0.0\"\n  port: 8080\n  limiter: false\n  public_instance: false\n  image_proxy: false\n  method: \"GET\"\n\
search:\n  formats:\n    - json\n  safe_search: 0\n  autocomplete: \"\"\n  default_lang: \"\"\n\
outgoing:\n  request_timeout: 6.0\n  max_request_timeout: 10.0\n  pool_connections: 20\n  pool_maxsize: 10\n\
ui:\n  static_use_hash: true\n"
    )
}

/// Every launch argument, fixed. The search service reaches the internet; the inference container never does.
pub fn launch_args(image: &str) -> Vec<String> {
    [
        "run",
        "-d",
        "--name",
        CONTAINER,
        "--label",
        "spark.service=searxng",
        "--label",
        "spark.local=true",
        "--restart",
        "unless-stopped",
        "--publish",
        "127.0.0.1:18119:8080",
        "--user",
        "977:977",
        "--read-only",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "--memory",
        "1g",
        "--memory-swap",
        "1g",
        "--cpus",
        "2",
        "--pids-limit",
        "256",
        "--tmpfs",
        "/tmp:rw,nosuid,nodev,noexec,size=64m,uid=977,gid=977",
        "--tmpfs",
        "/var/cache/searxng:rw,nosuid,nodev,noexec,size=64m,uid=977,gid=977",
        "--volume",
        "/var/lib/spark/searxng/settings.yml:/etc/searxng/settings.yml:ro",
        "--env",
        "SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml",
        "--env",
        "SEARXNG_BIND_ADDRESS=0.0.0.0",
        "--env",
        "SEARXNG_PORT=8080",
        "--env",
        "GRANIAN_WORKERS=2",
        image,
    ]
    .into_iter()
    .map(str::to_owned)
    .collect()
}

/// Why the settings file could not be written safely.
#[derive(Debug, thiserror::Error)]
pub enum SettingsWriteError {
    #[error("search settings directory is unavailable: {0}")]
    Directory(String),
    #[error("search settings path is a symbolic link")]
    Symlink,
    #[error("search settings are not owned by the helper")]
    Ownership,
    #[error("search settings could not be written: {0}")]
    Io(String),
}

fn fstat(fd: &std::os::fd::OwnedFd) -> Result<libc::stat, SettingsWriteError> {
    use std::os::fd::AsRawFd as _;
    let mut status: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd.as_raw_fd(), &mut status) } < 0 {
        return Err(SettingsWriteError::Io(
            std::io::Error::last_os_error().to_string(),
        ));
    }
    Ok(status)
}

/// Write `settings.yml` beneath `directory` through no-follow descriptors owned by this process, never through a path a link could redirect.
pub fn write_settings(
    directory: &std::path::Path,
    contents: &str,
) -> Result<(), SettingsWriteError> {
    use std::io::Write as _;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};
    use std::os::unix::ffi::OsStrExt as _;

    std::fs::create_dir_all(directory)
        .map_err(|error| SettingsWriteError::Directory(error.to_string()))?;
    let c_directory = std::ffi::CString::new(directory.as_os_str().as_bytes())
        .map_err(|_| SettingsWriteError::Directory("path contains NUL".into()))?;
    let raw = unsafe {
        libc::open(
            c_directory.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if raw < 0 {
        let error = std::io::Error::last_os_error();
        return Err(match error.raw_os_error() {
            Some(libc::ELOOP) | Some(libc::ENOTDIR) => SettingsWriteError::Symlink,
            _ => SettingsWriteError::Directory(error.to_string()),
        });
    }
    let parent = unsafe { OwnedFd::from_raw_fd(raw) };
    let owner = unsafe { libc::geteuid() };
    if fstat(&parent)?.st_uid != owner {
        return Err(SettingsWriteError::Ownership);
    }
    let raw = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            c"settings.yml".as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o644 as libc::c_uint,
        )
    };
    if raw < 0 {
        let error = std::io::Error::last_os_error();
        return Err(match error.raw_os_error() {
            Some(libc::ELOOP) | Some(libc::EMLINK) => SettingsWriteError::Symlink,
            _ => SettingsWriteError::Io(error.to_string()),
        });
    }
    let file = unsafe { OwnedFd::from_raw_fd(raw) };
    let status = fstat(&file)?;
    if (status.st_mode & libc::S_IFMT) != libc::S_IFREG || status.st_uid != owner {
        return Err(SettingsWriteError::Ownership);
    }
    // The container reads the file as its own unprivileged user, so it stays world-readable and helper-writable only.
    if unsafe { libc::fchmod(file.as_raw_fd(), 0o644) } < 0 {
        return Err(SettingsWriteError::Io(
            std::io::Error::last_os_error().to_string(),
        ));
    }
    let mut file = std::fs::File::from(file);
    file.write_all(contents.as_bytes())
        .and_then(|()| file.sync_all())
        .map_err(|error| SettingsWriteError::Io(error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt as _;

    #[test]
    fn settings_are_written_through_the_helper_owned_directory_with_a_fixed_mode() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("searxng");
        write_settings(&directory, "first").unwrap();
        write_settings(&directory, "second").unwrap();
        let path = directory.join("settings.yml");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "second");
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o644
        );
    }

    /// A link planted at the settings name must not redirect the root helper's write.
    #[test]
    fn a_symlink_at_the_settings_path_is_refused_and_its_target_untouched() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("searxng");
        std::fs::create_dir_all(&directory).unwrap();
        let victim = root.path().join("victim");
        std::fs::write(&victim, "keep").unwrap();
        std::os::unix::fs::symlink(&victim, directory.join("settings.yml")).unwrap();

        let error = write_settings(&directory, "redirected").unwrap_err();

        assert!(matches!(error, SettingsWriteError::Symlink), "{error}");
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep");
    }

    #[test]
    fn a_symlinked_settings_directory_is_refused() {
        let root = tempfile::tempdir().unwrap();
        let elsewhere = root.path().join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        let directory = root.path().join("searxng");
        std::os::unix::fs::symlink(&elsewhere, &directory).unwrap();

        let error = write_settings(&directory, "redirected").unwrap_err();

        assert!(matches!(error, SettingsWriteError::Symlink), "{error}");
        assert!(!elsewhere.join("settings.yml").exists());
    }

    #[test]
    fn search_is_pinned_loopback_only_and_cannot_write_to_its_own_image() {
        let args = launch_args(IMAGE);
        assert!(IMAGE.contains("@sha256:"));
        assert!(args.contains(&"127.0.0.1:18119:8080".into()));
        for value in ["--read-only", "no-new-privileges", "ALL", "977:977", "1g"] {
            assert!(args.contains(&value.into()), "{value} is not fixed");
        }
        assert!(
            args.contains(
                &"/var/lib/spark/searxng/settings.yml:/etc/searxng/settings.yml:ro".into()
            ),
            "the settings file is not mounted read-only"
        );
        assert!(
            !args
                .iter()
                .any(|v| v.contains("docker.sock") || v == "--privileged"),
            "the search service was given the host"
        );
        assert!(
            !args.iter().any(|v| v == "spark-inference-isolated"),
            "the search service was put on the inference network"
        );
        assert!(
            !args.iter().any(|v| v == "--gpus"),
            "the search service was given a GPU"
        );
    }

    #[test]
    fn the_settings_ask_for_json_and_turn_off_everything_that_phones_home() {
        let settings = settings_file("0123456789abcdef0123456789abcdef");
        assert!(settings.contains("secret_key: \"0123456789abcdef0123456789abcdef\""));
        assert!(settings.contains("formats:\n    - json"));
        for off in [
            "enable_metrics: false",
            "donation_url: false",
            "contact_url: false",
            "image_proxy: false",
            "public_instance: false",
            "limiter: false",
        ] {
            assert!(settings.contains(off), "{off} is not set");
        }
    }
}
