use super::*;
use std::os::unix::fs::symlink;

fn root() -> tempfile::TempDir {
    tempfile::tempdir().expect("tempdir")
}

#[test]
fn lexical_traversal_is_rejected_before_any_syscall() {
    for value in [
        "",
        "/",
        "/etc/passwd",
        "../outside",
        "a/../../outside",
        "./a",
        "a//b",
        "a/./b",
    ] {
        assert!(
            safe_components(value).is_err(),
            "{value:?} was accepted as a relative path"
        );
    }
    assert_eq!(safe_components("a/b/c.txt").unwrap(), ["a", "b", "c.txt"]);
}

#[test]
fn a_file_symlink_out_of_the_root_is_not_followed() {
    let directory = root();
    let outside = directory.path().join("outside-secret");
    std::fs::write(&outside, b"host secret").unwrap();
    let project = directory.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    symlink(&outside, project.join("escape.txt")).unwrap();

    let error = read_beneath(&project, "escape.txt").unwrap_err();
    assert!(
        matches!(error, BeneathError::Symlink(_)),
        "expected a symlink refusal, got {error}"
    );
}

#[test]
fn a_directory_symlink_out_of_the_root_is_not_traversed() {
    let directory = root();
    let outside = directory.path().join("outside");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("secret.txt"), b"host secret").unwrap();
    let project = directory.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    symlink(&outside, project.join("link")).unwrap();

    let error = read_beneath(&project, "link/secret.txt").unwrap_err();
    assert!(
        matches!(error, BeneathError::Symlink(_)),
        "expected a symlink refusal, got {error}"
    );

    std::fs::write(project.join("real.txt"), b"in project").unwrap();
    let listed = list_beneath(&project, 8, 100).unwrap();
    assert_eq!(
        listed
            .iter()
            .map(|entry| entry.relative_path.as_str())
            .collect::<Vec<_>>(),
        vec!["real.txt"]
    );
}

#[test]
fn an_absolute_symlink_to_a_root_directory_is_refused() {
    let directory = root();
    let project = directory.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    symlink("/", project.join("slash")).unwrap();
    let error = read_beneath(&project, "slash/etc/hosts").unwrap_err();
    assert!(matches!(error, BeneathError::Symlink(_)), "{error}");
}

#[test]
fn writes_do_not_follow_a_symlink_and_are_atomic() {
    let directory = root();
    let outside = directory.path().join("outside.txt");
    std::fs::write(&outside, b"original").unwrap();
    let project = directory.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    symlink(&outside, project.join("target.txt")).unwrap();

    // Replace the link with a regular file using renameat rather than writing through it.
    write_beneath(&project, "target.txt", b"overwritten").unwrap();
    assert_eq!(
        std::fs::read(&outside).unwrap(),
        b"original",
        "the host file the link pointed at must be untouched"
    );
    assert_eq!(
        read_beneath(&project, "target.txt").unwrap(),
        b"overwritten"
    );
    assert!(
        !std::fs::symlink_metadata(project.join("target.txt"))
            .unwrap()
            .file_type()
            .is_symlink(),
        "the escape link is gone, replaced by a real file"
    );

    // A plain write works and leaves no temporary behind.
    write_beneath(&project, "notes.txt", b"hello").unwrap();
    assert_eq!(read_beneath(&project, "notes.txt").unwrap(), b"hello");
    let leftovers: Vec<_> = std::fs::read_dir(&project)
        .unwrap()
        .filter_map(|entry| entry.ok())
        .filter(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".spark-tmp-")
        })
        .collect();
    assert!(leftovers.is_empty(), "temporary files left behind");
}

#[test]
fn a_rename_race_cannot_redirect_a_write() {
    // Create with O_EXCL and rename through the opened parent so a swapped target symlink is replaced, never followed.
    let directory = root();
    let outside = directory.path().join("outside.txt");
    std::fs::write(&outside, b"original").unwrap();
    let project = directory.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(project.join("file.txt"), b"before").unwrap();

    std::fs::remove_file(project.join("file.txt")).unwrap();
    symlink(&outside, project.join("file.txt")).unwrap();
    write_beneath(&project, "file.txt", b"after").unwrap();

    assert_eq!(
        std::fs::read(&outside).unwrap(),
        b"original",
        "the host file must be untouched"
    );
    assert_eq!(read_beneath(&project, "file.txt").unwrap(), b"after");
}

#[test]
fn directories_are_created_without_traversing_a_link() {
    let directory = root();
    let outside = directory.path().join("outside");
    std::fs::create_dir_all(&outside).unwrap();
    let project = directory.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    symlink(&outside, project.join("link")).unwrap();

    assert!(create_dir_all_beneath(&project, "link/nested").is_err());
    assert!(!outside.join("nested").exists());

    create_dir_all_beneath(&project, "src/models").unwrap();
    assert!(project.join("src/models").is_dir());
}

#[test]
fn a_fifo_is_not_served_as_a_file() {
    let directory = root();
    let project = directory.path().join("project");
    std::fs::create_dir_all(&project).unwrap();
    let fifo = project.join("pipe");
    let name = CString::new(fifo.as_os_str().as_bytes()).unwrap();
    // Best-effort: skip where mkfifo is unavailable.
    if unsafe { libc::mkfifo(name.as_ptr(), 0o600) } != 0 {
        return;
    }
    let listed = list_beneath(&project, 4, 50).unwrap();
    assert!(listed.is_empty(), "a FIFO is not editable content");
}
