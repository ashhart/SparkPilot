use super::*;

#[test]
fn a_symlinked_destination_is_replaced_not_written_through() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    std::fs::create_dir(&state).unwrap();

    let victim = dir.path().join("victim");
    std::fs::write(&victim, b"root content").unwrap();
    std::os::unix::fs::symlink(&victim, state.join("runtime.db")).unwrap();

    // Use the test process uid/gid so restored-byte placement can be verified without privileged chown.
    let uid = unsafe { libc::getuid() };
    let gid = unsafe { libc::getgid() };
    let parent = open_trusted_directory(&state).unwrap();
    write_child(&parent, "runtime.db", b"restored", 0o640, uid, gid, &state).unwrap();

    // The target is untouched and the destination is a real file again.
    assert_eq!(std::fs::read(&victim).unwrap(), b"root content");
    assert_eq!(
        std::fs::read(state.join("runtime.db")).unwrap(),
        b"restored"
    );
    assert!(
        !std::fs::symlink_metadata(state.join("runtime.db"))
            .unwrap()
            .file_type()
            .is_symlink()
    );
}

#[test]
fn a_symlinked_write_ahead_log_is_unlinked_not_followed() {
    let dir = tempfile::tempdir().unwrap();
    let state = dir.path().join("state");
    std::fs::create_dir(&state).unwrap();
    let victim = dir.path().join("victim");
    std::fs::write(&victim, b"root content").unwrap();
    std::os::unix::fs::symlink(&victim, state.join("runtime.db-wal")).unwrap();

    let parent = open_trusted_directory(&state).unwrap();
    assert!(unlink_child(&parent, "runtime.db-wal").unwrap());

    assert!(victim.exists(), "the target must survive");
    assert_eq!(std::fs::read(&victim).unwrap(), b"root content");
    assert!(!state.join("runtime.db-wal").exists());
}

#[test]
fn removing_something_that_is_not_there_is_not_an_error() {
    let dir = tempfile::tempdir().unwrap();
    let parent = open_trusted_directory(dir.path()).unwrap();
    assert!(!unlink_child(&parent, "runtime.db-shm").unwrap());
}

/// The backup lives in a root-only directory, but its members are still read through no-follow, bounded opens.
#[test]
fn a_symlinked_backup_member_is_refused_not_followed() {
    let dir = tempfile::tempdir().unwrap();
    let secret = dir.path().join("secret");
    std::fs::write(&secret, b"root only").unwrap();
    let member = dir.path().join("runtime.db");
    std::os::unix::fs::symlink(&secret, &member).unwrap();

    let error = read_backup_member(&member, MAX_RESTORED_DATABASE_BYTES).unwrap_err();

    assert!(matches!(error, StateError::Symlink { .. }), "{error}");
}

#[test]
fn an_absent_backup_member_is_skipped_and_an_oversized_one_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    assert!(
        read_backup_member(&dir.path().join("config.toml"), 16)
            .unwrap()
            .is_none()
    );
    let member = dir.path().join("config.toml");
    std::fs::write(&member, b"0123456789abcdef!").unwrap();
    let error = read_backup_member(&member, 16).unwrap_err();
    assert!(matches!(error, StateError::FileTooLarge { .. }), "{error}");
    std::fs::write(&member, b"0123456789abcdef").unwrap();
    assert_eq!(
        read_backup_member(&member, 16).unwrap().unwrap(),
        b"0123456789abcdef"
    );
}
