use super::account::is_zombie;
use super::*;

#[test]
fn the_state_of_a_process_is_read_after_the_last_parenthesis() {
    // Names containing spaces, parentheses or fake state fields must not make a live process appear to be a zombie.
    let dir = tempfile::tempdir().unwrap();
    let cases = [
        ("1 (sparkd) Z 0 1 1 0 -1 4194304", true),
        ("1 (sparkd) S 0 1 1 0 -1 4194304", false),
        ("1 (weird name with spaces) Z 0 1", true),
        ("1 (has) (parens) R 0 1", false),
        // A live process named Z must not be classified by its name instead of its state.
        ("1 (Z) R 0 1", false),
        ("1 (evil) Z (", true),
    ];
    for (index, (stat, expected)) in cases.iter().enumerate() {
        let proc_dir = dir.path().join(format!("proc{index}"));
        std::fs::create_dir(&proc_dir).unwrap();
        std::fs::write(proc_dir.join("stat"), stat).unwrap();
        assert_eq!(is_zombie(&proc_dir), *expected, "case {index}: {stat}");
    }
}

#[test]
fn an_unreadable_proc_entry_is_not_reported_as_a_zombie() {
    // A disappearing process is not proven exited by unreadable procfs; retain caller rechecking.
    let dir = tempfile::tempdir().unwrap();
    assert!(!is_zombie(&dir.path().join("nothing-here")));
}

#[test]
fn this_process_is_not_a_zombie() {
    // Check parsing against this process's real Linux procfs record when available.
    let proc_dir = PathBuf::from(format!("/proc/{}", std::process::id()));
    if proc_dir.join("stat").exists() {
        assert!(!is_zombie(&proc_dir));
        // SAFETY: getuid cannot fail and touches no memory.
        let uid = unsafe { libc::getuid() };
        assert!(
            process_running_as(uid).is_some(),
            "the scan finds this very process"
        );
    }
}

#[test]
fn a_symlink_where_a_directory_belongs_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let victim = dir.path().join("victim");
    std::fs::create_dir(&victim).unwrap();
    std::os::unix::fs::symlink(&victim, dir.path().join("identity")).unwrap();

    let parent = open_trusted_directory(dir.path()).unwrap();
    let error =
        open_or_create_child(&parent, "identity", 0o700, &dir.path().join("identity")).unwrap_err();
    assert!(
        matches!(error, StateError::Symlink { .. }),
        "expected a symlink refusal, got {error:?}"
    );
}

#[test]
fn a_dangling_symlink_is_refused_rather_than_created_through() {
    let dir = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(dir.path().join("nowhere"), dir.path().join("models")).unwrap();

    let parent = open_trusted_directory(dir.path()).unwrap();
    let error =
        open_or_create_child(&parent, "models", 0o750, &dir.path().join("models")).unwrap_err();
    assert!(matches!(error, StateError::Symlink { .. }), "got {error:?}");
    // And nothing was created at the link's target.
    assert!(!dir.path().join("nowhere").exists());
}

#[test]
fn a_regular_file_where_a_directory_belongs_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("projects"), b"not a directory").unwrap();

    let parent = open_trusted_directory(dir.path()).unwrap();
    let error =
        open_or_create_child(&parent, "projects", 0o750, &dir.path().join("projects")).unwrap_err();
    assert!(
        matches!(error, StateError::NotADirectory { .. }),
        "got {error:?}"
    );
}

#[test]
fn creating_and_reopening_is_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let parent = open_trusted_directory(dir.path()).unwrap();
    let display = dir.path().join("identity");

    let first = open_or_create_child(&parent, "identity", 0o700, &display).unwrap();
    set_mode(&first, 0o700, &display).unwrap();
    drop(first);

    let second = open_or_create_child(&parent, "identity", 0o700, &display).unwrap();
    drop(second);

    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(&display).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o700);
}

#[test]
fn a_symlinked_trusted_parent_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let real = dir.path().join("real");
    std::fs::create_dir(&real).unwrap();
    let link = dir.path().join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();

    let error = open_trusted_directory(&link).unwrap_err();
    assert!(matches!(error, StateError::Symlink { .. }), "got {error:?}");
}
