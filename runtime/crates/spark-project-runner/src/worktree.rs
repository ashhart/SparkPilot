//! Create agent checkouts from explicit base commits and run allowlisted Git operations through the testable GitRunner boundary.

use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};

use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum WorktreeError {
    #[error("git failed: {0}")]
    Git(String),
    #[error("refusing branch name {0:?} (allowlist: agent-<uuid>)")]
    InvalidBranch(String),
    #[error("worktree path escapes the worktrees root: {0}")]
    UnsafePath(String),
    #[error("path traversal rejected: {0}")]
    Traversal(String),
    #[error("base commit must be 40..=64 lowercase hex chars")]
    InvalidCommit,
    #[error("repository URL rejected: {0}")]
    UnsafeUrl(String),
}

/// The agent-branch naming contract: `agent-<uuid>`.
pub fn agent_branch_name(operation_id: Uuid) -> String {
    format!("agent-{operation_id}")
}

/// Git execution boundary (test doubles script commands).
pub trait GitRunner: Send + Sync {
    /// Run against `repo` as the working tree.
    fn run(&self, repo: &Path, args: &[&str]) -> Result<String, String>;
    /// Run with an explicit working directory (clone into a fresh dir).
    fn run_cwd(&self, cwd: &Path, args: &[&str]) -> Result<String, String>;
    /// Read container-owned Git data through a runtime-owned metadata snapshot.
    fn run_isolated(&self, repo: &Path, args: &[&str]) -> Result<String, String> {
        self.run(repo, args)
    }
    /// Import reviewed objects without consulting container-owned configuration.
    fn import_reviewed(
        &self,
        main: &Path,
        source: &Path,
        head: &str,
        branch: &str,
    ) -> Result<(), String> {
        self.run(
            main,
            &[
                "fetch",
                "--no-tags",
                "--no-write-fetch-head",
                &source.display().to_string(),
                &format!("{head}:refs/heads/{branch}"),
            ],
        )
        .map(|_| ())
    }
}

/// Bound each Git invocation so an unreachable or deliberately slow remote cannot hold an operation worker indefinitely.
pub const GIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(600);
/// Capture only a bounded diagnostic prefix of potentially unbounded Git output.
pub const GIT_OUTPUT_CAP: usize = 1024 * 1024;

/// Use a fixed runtime commit identity because host configuration is neither inherited nor dependable.
pub const COMMIT_NAME: &str = "Spark Runtime";
pub const COMMIT_EMAIL: &str = "runtime@spark.invalid";

/// Run allowlisted Git arguments with scrubbed environment, disabled config discovery, explicit protocols and a deadline; see RUNTIME-INVARIANTS.md.
#[derive(Debug, Clone)]
pub struct CommandGit {
    git_bin: String,
    timeout: std::time::Duration,
}

impl CommandGit {
    pub fn new(git_bin: impl Into<String>) -> Self {
        Self {
            git_bin: git_bin.into(),
            timeout: GIT_TIMEOUT,
        }
    }

    /// Override the per-invocation wall-clock budget (tests, slow mirrors).
    pub fn with_timeout(mut self, timeout: std::time::Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Build Git commands with a cleared environment and configuration discovery disabled.
    fn command(&self, cwd: &Path) -> std::process::Command {
        let mut command = std::process::Command::new(&self.git_bin);
        command
            .args(["-c", "protocol.allow=never"])
            .args(["-c", "protocol.https.allow=always"])
            .args(["-c", "protocol.file.allow=always"])
            .args(["-c", "core.symlinks=false"])
            .args(["-c", "core.fsmonitor=false"])
            .args(["-c", "core.hooksPath=/dev/null"])
            .args(["-c", "core.attributesFile=/dev/null"])
            .args(["-c", "commit.gpgSign=false"])
            .args(["-c", "tag.gpgSign=false"])
            .args(["-c", "maintenance.auto=false"])
            .args(["-c", "gc.auto=0"])
            .args(["-c", "fetch.fsckObjects=true"])
            .args(["-c", "transfer.fsckObjects=true"])
            .args(["-c", "credential.helper="])
            .args(["-c", "diff.external="])
            // Supply runtime commit identity explicitly because disabled global config and domainless hostnames leave no reliable fallback.
            .args(["-c", &format!("user.name={COMMIT_NAME}")])
            .args(["-c", &format!("user.email={COMMIT_EMAIL}")])
            .current_dir(cwd)
            // Clear inherited GIT_SSH_COMMAND, GIT_EXTERNAL_DIFF, GIT_PROXY_COMMAND and GIT_CONFIG overrides before setting approved values.
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/local/bin")
            .env("HOME", cwd)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            // Disable credential prompts so daemon operations cannot wait for interactive login.
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_ASKPASS", "")
            .env("SSH_ASKPASS", "")
            .stdin(std::process::Stdio::null());
        command
    }

    fn execute(&self, cwd: &Path, args: &[&str]) -> Result<String, String> {
        use nix::fcntl::{FcntlArg, OFlag, fcntl};
        use std::os::fd::AsFd as _;
        let mut child = self
            .command(cwd)
            .args(args)
            .process_group(0)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|error| error.to_string())?;
        let mut stdout = child.stdout.take().expect("piped stdout");
        let mut stderr = child.stderr.take().expect("piped stderr");
        let result = (|| {
            for pipe in [stdout.as_fd(), stderr.as_fd()] {
                fcntl(pipe, FcntlArg::F_SETFL(OFlag::O_NONBLOCK))
                    .map_err(|error| error.to_string())?;
            }
            let mut captured = [Vec::new(), Vec::new()];
            let mut closed = [false, false];
            let deadline = std::time::Instant::now() + self.timeout;
            let mut status = None;
            loop {
                for (index, pipe) in [&mut stdout as &mut dyn std::io::Read, &mut stderr]
                    .into_iter()
                    .enumerate()
                {
                    if closed[index] {
                        continue;
                    }
                    // A noisy stream cannot starve its peer or the deadline.
                    for _ in 0..16 {
                        let mut buffer = [0_u8; 16 * 1024];
                        match pipe.read(&mut buffer) {
                            Ok(0) => {
                                closed[index] = true;
                                break;
                            }
                            Ok(count) => {
                                let retained =
                                    count.min(GIT_OUTPUT_CAP.saturating_sub(captured[index].len()));
                                captured[index].extend_from_slice(&buffer[..retained]);
                            }
                            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {
                                continue;
                            }
                            Err(error) => return Err(error.to_string()),
                        }
                    }
                }
                if status.is_none() {
                    status = child.try_wait().map_err(|error| error.to_string())?;
                }
                if let Some(status) = status.filter(|_| closed.iter().all(|value| *value)) {
                    let cap = |bytes: &[u8]| String::from_utf8_lossy(bytes).trim().to_owned();
                    return if status.success() {
                        Ok(cap(&captured[0]))
                    } else {
                        Err(cap(&captured[1]))
                    };
                }
                if std::time::Instant::now() >= deadline {
                    return Err(format!(
                        "git timed out after {} seconds",
                        self.timeout.as_secs()
                    ));
                }
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        })();
        // Kill descendant process groups after failure or timeout so inherited output pipes cannot hold the reader open.
        if result.is_err() {
            let _ = nix::sys::signal::killpg(
                nix::unistd::Pid::from_raw(child.id() as i32),
                nix::sys::signal::Signal::SIGKILL,
            );
        }
        let _ = child.wait();
        result
    }
}

impl GitRunner for CommandGit {
    fn run(&self, repo: &Path, args: &[&str]) -> Result<String, String> {
        self.execute(repo, args)
    }

    fn run_cwd(&self, cwd: &Path, args: &[&str]) -> Result<String, String> {
        // Local upload-pack receives only a sanitized data snapshot, including clones of managed checkouts.
        if args.first() == Some(&"clone") && args.len() >= 3 {
            let source_index = args.len() - 2;
            let source = args[source_index];
            let local = if source.starts_with("file://") {
                Some(
                    url::Url::parse(source)
                        .map_err(|error| error.to_string())?
                        .to_file_path()
                        .map_err(|_| "invalid local repository URL")?,
                )
            } else if Path::new(source).is_absolute() {
                Some(PathBuf::from(source))
            } else {
                None
            };
            if let Some(local) = local {
                let snapshot = crate::git_snapshot::snapshot(&local)?;
                let source = snapshot.path().display().to_string();
                let mut cloned = args.to_vec();
                cloned[source_index] = source.as_str();
                return self.execute(cwd, &cloned);
            }
        }
        self.execute(cwd, args)
    }

    fn run_isolated(&self, repo: &Path, args: &[&str]) -> Result<String, String> {
        let snapshot = crate::git_snapshot::snapshot(repo)?;
        let git_dir = format!("--git-dir={}", snapshot.path().display());
        let work_tree = format!("--work-tree={}", repo.display());
        let mut isolated = vec![git_dir.as_str(), work_tree.as_str()];
        isolated.extend_from_slice(args);
        self.execute(snapshot.path(), &isolated)
    }

    fn import_reviewed(
        &self,
        main: &Path,
        source: &Path,
        head: &str,
        branch: &str,
    ) -> Result<(), String> {
        validate_commit(head).map_err(|error| error.to_string())?;
        validate_branch(branch).map_err(|error| error.to_string())?;
        let snapshot = crate::git_snapshot::snapshot(source)?;
        self.execute(
            main,
            &[
                "fetch",
                "--no-tags",
                "--no-write-fetch-head",
                "--force",
                "--",
                &snapshot.path().display().to_string(),
                &format!("{head}:refs/heads/{branch}"),
            ],
        )
        .map(|_| ())
    }
}

/// Allow only HTTPS and local file mirrors; reject Git remote-helper schemes, ext syntax and SCP-style addresses.
pub fn validate_repository_url(url: &str) -> Result<(), WorktreeError> {
    if url.is_empty() || url.len() > 2048 {
        return Err(WorktreeError::UnsafeUrl("length out of range".into()));
    }
    if url.contains(['\0', '\n', '\r']) || url.chars().any(|c| c.is_control()) {
        return Err(WorktreeError::UnsafeUrl(
            "control characters are not permitted".into(),
        ));
    }
    // A leading `-` would be read as an option however it is positioned.
    if url.starts_with('-') {
        return Err(WorktreeError::UnsafeUrl(
            "a repository URL may not start with '-'".into(),
        ));
    }
    let Some((scheme, rest)) = url.split_once("://") else {
        return Err(WorktreeError::UnsafeUrl(
            "only https:// and file:// URLs are accepted".into(),
        ));
    };
    if !matches!(scheme, "https" | "file") {
        return Err(WorktreeError::UnsafeUrl(format!(
            "scheme {scheme:?} is not allowed"
        )));
    }
    if rest.is_empty() {
        return Err(WorktreeError::UnsafeUrl("empty repository path".into()));
    }
    // Keep HTTPS credentials out of argv and reflogs; use the provider-credential store instead.
    if scheme == "https" && rest.split('/').next().is_some_and(|a| a.contains('@')) {
        return Err(WorktreeError::UnsafeUrl(
            "credentials in a repository URL are not accepted".into(),
        ));
    }
    Ok(())
}

fn validate_branch(branch: &str) -> Result<(), WorktreeError> {
    let allowed_starts = ["agent-", "preview-"];
    if !allowed_starts
        .iter()
        .any(|prefix| branch.starts_with(prefix))
    {
        return Err(WorktreeError::InvalidBranch(branch.to_owned()));
    }
    let id = &branch[branch.find('-').map_or(0, |i| i + 1)..];
    if !id.chars().all(|c| c.is_ascii_hexdigit() || c == '-') || id.is_empty() {
        return Err(WorktreeError::InvalidBranch(branch.to_owned()));
    }
    Ok(())
}

fn validate_commit(commit: &str) -> Result<(), WorktreeError> {
    if commit.len() < 40 || commit.len() > 64 || !commit.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(WorktreeError::InvalidCommit);
    }
    Ok(())
}

/// Resolve a worktree path strictly under `root` (rejects `..`, separators).
pub fn safe_worktree_path(root: &Path, branch: &str) -> Result<PathBuf, WorktreeError> {
    if branch.contains('/') || branch.contains("..") || branch.starts_with('.') {
        return Err(WorktreeError::UnsafePath(branch.to_owned()));
    }
    let candidate = root.join(branch);
    if !candidate.starts_with(root) {
        return Err(WorktreeError::Traversal(candidate.display().to_string()));
    }
    Ok(candidate)
}

/// Clone (or make sure exists) the main protected checkout at `main_dir`.
pub fn ensure_main_checkout(
    runner: &dyn GitRunner,
    main_dir: &Path,
    repository_url: Option<&str>,
    revision: Option<&str>,
) -> Result<(), WorktreeError> {
    if main_dir.join(".git").exists() {
        return Ok(()); // already cloned
    }
    let Some(url) = repository_url else {
        // Local/template project: initialise an empty protected checkout.
        runner
            .run_cwd(main_dir, &["init", "-b", "main"])
            .map_err(WorktreeError::Git)?;
        runner
            .run(main_dir, &["config", "user.email", "spark@local"])
            .map_err(WorktreeError::Git)?;
        runner
            .run(main_dir, &["config", "user.name", "Spark"])
            .map_err(WorktreeError::Git)?;
        return Ok(());
    };
    validate_repository_url(url)?;
    runner
        .run_cwd(
            main_dir.parent().unwrap_or(Path::new(".")),
            &[
                "clone",
                "--quiet",
                "--no-checkout",
                // Terminate option parsing even after URL validation so the repository cannot be interpreted as a flag.
                "--",
                url,
                &main_dir_file_name(main_dir),
            ],
        )
        .map_err(WorktreeError::Git)?;
    runner
        .run(main_dir, &["remote", "set-url", "origin", url])
        .map_err(WorktreeError::Git)?;
    if let Some(commit) = revision {
        validate_commit(commit)?;
        runner
            .run(main_dir, &["checkout", "--quiet", "-B", "main", commit])
            .map_err(WorktreeError::Git)?;
    } else {
        runner
            .run(main_dir, &["checkout", "--quiet", "-B", "main", "HEAD"])
            .map_err(WorktreeError::Git)?;
    }
    Ok(())
}

#[allow(clippy::needless_borrow)]
fn main_dir_file_name(main_dir: &Path) -> String {
    main_dir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "project".to_owned())
}

/// Create `worktrees/agent-<operation-id>` at `base_commit`.
pub fn create_agent_worktree(
    runner: &dyn GitRunner,
    main_dir: &Path,
    worktrees_root: &Path,
    operation_id: Uuid,
    base_commit: &str,
) -> Result<PathBuf, WorktreeError> {
    validate_commit(base_commit)?;
    let branch = agent_branch_name(operation_id);
    validate_branch(&branch)?;
    std::fs::create_dir_all(worktrees_root).map_err(|e| WorktreeError::Git(e.to_string()))?;
    let path = safe_worktree_path(worktrees_root, &branch)?;
    // Use an independent detached object database without hardlinks or alternates; linked worktrees escape the container's mount.
    runner
        .run_cwd(
            worktrees_root,
            &[
                "clone",
                "--quiet",
                "--no-local",
                "--no-hardlinks",
                "--no-checkout",
                "--",
                &main_dir.display().to_string(),
                &path.display().to_string(),
            ],
        )
        .map_err(WorktreeError::Git)?;
    runner
        .run(&path, &["checkout", "--quiet", "-b", &branch, base_commit])
        .map_err(WorktreeError::Git)?;
    runner
        .run(&path, &["remote", "remove", "origin"])
        .map_err(WorktreeError::Git)?;
    Ok(path)
}

/// List legacy linked worktrees here; enumerate managed independent checkouts from the durable registry.
pub fn worktree_list(
    runner: &dyn GitRunner,
    main_dir: &Path,
) -> Result<Vec<String>, WorktreeError> {
    let output = runner
        .run(main_dir, &["worktree", "list", "--porcelain"])
        .map_err(WorktreeError::Git)?;
    Ok(output
        .lines()
        .filter_map(|line| line.strip_prefix("worktree "))
        .map(|p| p.to_owned())
        .collect())
}

/// Squash-merge an agent branch into the protected main checkout.
pub fn squash_merge(
    runner: &dyn GitRunner,
    main_dir: &Path,
    branch: &str,
    message: &str,
    author: &str,
) -> Result<(), WorktreeError> {
    validate_branch(branch)?;
    runner
        .run(main_dir, &["checkout", "--quiet", "main"])
        .map_err(WorktreeError::Git)?;
    runner
        .run(main_dir, &["merge", "--squash", "--quiet", branch])
        .map_err(WorktreeError::Git)?;
    runner
        .run(
            main_dir,
            &["commit", "--quiet", "-m", message, "--author", author],
        )
        .map_err(WorktreeError::Git)?;
    Ok(())
}

/// Remove a managed checkout, refusing every path outside its trusted root.
pub fn remove_worktree(
    runner: &dyn GitRunner,
    main_dir: &Path,
    worktrees_root: &Path,
    path: &Path,
) -> Result<(), WorktreeError> {
    let branch = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| WorktreeError::UnsafePath(path.display().to_string()))?;
    validate_branch(branch)?;
    let managed_root = std::fs::canonicalize(worktrees_root)
        .map_err(|error| WorktreeError::Git(error.to_string()))?;
    let canonical =
        std::fs::canonicalize(path).map_err(|error| WorktreeError::Git(error.to_string()))?;
    if canonical.parent() != Some(managed_root.as_path())
        || path == main_dir
        || std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink())
    {
        return Err(WorktreeError::UnsafePath(path.display().to_string()));
    }
    if path.join(".git").is_dir() {
        std::fs::remove_dir_all(path).map_err(|error| WorktreeError::Git(error.to_string()))
    } else {
        runner
            .run(
                main_dir,
                &["worktree", "remove", "--force", &path.display().to_string()],
            )
            .map(|_| ())
            .map_err(WorktreeError::Git)
    }
}

/// Porcelain status of the agent worktree (used for diffs and CI gates).
pub fn status_porcelain(runner: &dyn GitRunner, worktree: &Path) -> Result<String, WorktreeError> {
    runner
        .run(
            worktree,
            &["status", "--porcelain=v1", "--untracked-files=all"],
        )
        .map_err(WorktreeError::Git)
}

#[cfg(test)]
#[path = "worktree/tests.rs"]
mod tests;
