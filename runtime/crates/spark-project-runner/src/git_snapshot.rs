//! Review immutable Git data without sandbox-controlled configuration, hooks, alternates or linked-worktree control files.

use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsFd, OwnedFd};
use std::path::Path;

use nix::fcntl::{OFlag, open, openat};
use nix::sys::stat::Mode;

const MAX_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_ENTRIES: usize = 100_000;

struct Budget {
    bytes: u64,
    entries: usize,
}

fn directory_at(parent: &impl AsFd, name: &str) -> Result<OwnedFd, String> {
    openat(
        parent,
        name,
        OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
        Mode::empty(),
    )
    .map_err(|error| error.to_string())
}

fn copy_file(
    parent: &impl AsFd,
    name: &str,
    destination: &Path,
    budget: &mut Budget,
) -> Result<(), String> {
    let fd = openat(
        parent,
        name,
        OFlag::O_RDONLY | OFlag::O_NOFOLLOW | OFlag::O_NONBLOCK | OFlag::O_CLOEXEC,
        Mode::empty(),
    )
    .map_err(|error| error.to_string())?;
    let source = File::from(fd);
    let metadata = source.metadata().map_err(|error| error.to_string())?;
    let file_budget = match name {
        "HEAD" => budget.bytes.min(4096),
        "packed-refs" => budget.bytes.min(16 * 1024 * 1024),
        _ => budget.bytes,
    };
    if !metadata.is_file() || metadata.len() > file_budget || budget.entries == 0 {
        return Err("REVIEW_GIT_DATA_REFUSED: nonregular or oversized Git data".into());
    }
    budget.entries -= 1;
    let mut output = File::create(destination).map_err(|error| error.to_string())?;
    let count = std::io::copy(&mut source.take(file_budget + 1), &mut output)
        .map_err(|error| error.to_string())?;
    if count > file_budget {
        return Err("REVIEW_GIT_DATA_TOO_LARGE".into());
    }
    budget.bytes -= count;
    output.flush().map_err(|error| error.to_string())
}

fn entries(fd: &OwnedFd, budget: &mut Budget) -> Result<Vec<String>, String> {
    let mut directory =
        nix::dir::Dir::from_fd(nix::unistd::dup(fd).map_err(|error| error.to_string())?)
            .map_err(|error| error.to_string())?;
    let mut names = Vec::new();
    for entry in directory.iter() {
        let entry = entry.map_err(|error| error.to_string())?;
        let name = entry
            .file_name()
            .to_str()
            .map_err(|_| "non-UTF8 Git metadata")?;
        if name != "." && name != ".." {
            if budget.entries == 0 {
                return Err("REVIEW_GIT_DATA_TOO_LARGE".into());
            }
            budget.entries -= 1;
            names.push(name.to_owned());
        }
    }
    Ok(names)
}

fn copy_refs(
    source: &OwnedFd,
    destination: &Path,
    budget: &mut Budget,
    depth: usize,
) -> Result<(), String> {
    if depth > 16 || budget.entries == 0 {
        return Err("REVIEW_GIT_DATA_TOO_LARGE".into());
    }
    budget.entries -= 1;
    std::fs::create_dir_all(destination).map_err(|error| error.to_string())?;
    for name in entries(source, budget)? {
        if name.ends_with(".lock") {
            continue;
        }
        match directory_at(source, &name) {
            Ok(child) => copy_refs(&child, &destination.join(&name), budget, depth + 1)?,
            Err(_) => copy_file(source, &name, &destination.join(&name), budget)?,
        }
    }
    Ok(())
}

fn hex(value: &str) -> bool {
    value
        .bytes()
        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Copy refs/index/objects through no-follow descriptors; exclude config, hooks, alternates, commondir, shallow indirections and symlinks.
pub(crate) fn snapshot(repository: &Path) -> Result<tempfile::TempDir, String> {
    let root = open(
        repository,
        OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
        Mode::empty(),
    )
    .map_err(|error| error.to_string())?;
    let source = match openat(
        &root,
        ".git",
        OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
        Mode::empty(),
    ) {
        Ok(source) => source,
        // A local bare mirror has its data directly beneath its root.
        Err(nix::errno::Errno::ENOENT) => root,
        Err(error) => return Err(error.to_string()),
    };
    let snapshot = tempfile::Builder::new()
        .prefix("spark-git-review-")
        .tempdir()
        .map_err(|error| error.to_string())?;
    let target = snapshot.path();
    let mut budget = Budget {
        bytes: MAX_BYTES,
        entries: MAX_ENTRIES,
    };
    copy_file(&source, "HEAD", &target.join("HEAD"), &mut budget)?;
    for name in ["index", "packed-refs"] {
        match openat(
            &source,
            name,
            OFlag::O_RDONLY | OFlag::O_NOFOLLOW | OFlag::O_NONBLOCK | OFlag::O_CLOEXEC,
            Mode::empty(),
        ) {
            Err(nix::errno::Errno::ENOENT) => continue,
            Err(error) => return Err(error.to_string()),
            Ok(_) => copy_file(&source, name, &target.join(name), &mut budget)?,
        }
    }
    let refs = directory_at(&source, "refs")?;
    copy_refs(&refs, &target.join("refs"), &mut budget, 0)?;
    let objects = directory_at(&source, "objects")?;
    std::fs::create_dir(target.join("objects")).map_err(|error| error.to_string())?;
    for name in entries(&objects, &mut budget)? {
        if name.len() == 2 && hex(&name) {
            let child = directory_at(&objects, &name)?;
            let destination = target.join("objects").join(&name);
            std::fs::create_dir(&destination).map_err(|error| error.to_string())?;
            for object in entries(&child, &mut budget)? {
                if matches!(object.len(), 38 | 62) && hex(&object) {
                    copy_file(&child, &object, &destination.join(&object), &mut budget)?;
                }
            }
        } else if name == "pack" {
            let child = directory_at(&objects, "pack")?;
            let destination = target.join("objects/pack");
            std::fs::create_dir(&destination).map_err(|error| error.to_string())?;
            for pack in entries(&child, &mut budget)? {
                let Some((stem, extension)) = pack.rsplit_once('.') else {
                    continue;
                };
                let Some(hash) = stem.strip_prefix("pack-") else {
                    continue;
                };
                if matches!(hash.len(), 40 | 64)
                    && hex(hash)
                    && matches!(extension, "pack" | "idx" | "rev")
                {
                    copy_file(&child, &pack, &destination.join(&pack), &mut budget)?;
                }
            }
        }
    }
    // HEAD is the only permitted symbolic indirection and must remain in refs.
    let head = std::fs::read_to_string(target.join("HEAD")).map_err(|error| error.to_string())?;
    let head = head.trim();
    let object = if let Some(reference) = head.strip_prefix("ref: ") {
        if !reference.starts_with("refs/")
            || reference
                .split('/')
                .any(|part| part.is_empty() || part == "." || part == "..")
        {
            return Err("REVIEW_GIT_DATA_REFUSED: invalid HEAD".into());
        }
        // Prefer loose tips for independently cloned SHA-256 repositories; only Git interprets packed refs.
        std::fs::read_to_string(target.join(reference)).unwrap_or_else(|_| {
            std::fs::read_to_string(target.join("packed-refs"))
                .unwrap_or_default()
                .lines()
                .find_map(|line| {
                    line.split_once(' ')
                        .filter(|(_, name)| *name == reference)
                        .map(|(object, _)| object.to_owned())
                })
                .unwrap_or_default()
        })
    } else {
        head.to_owned()
    };
    let config = if object.trim().len() == 64 && hex(object.trim()) {
        "[core]\nrepositoryformatversion = 1\nbare = true\n[extensions]\nobjectformat = sha256\n"
    } else {
        "[core]\nrepositoryformatversion = 0\nbare = true\n"
    };
    std::fs::write(target.join("config"), config).map_err(|error| error.to_string())?;
    Ok(snapshot)
}
