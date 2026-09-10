use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use sha2::Digest;

use crate::project::{ProjectManager, ProjectView};

pub const REVIEW_EVIDENCE_SCHEMA: u32 = 1;
const MAX_CHANGED_FILES: usize = 2_000;
const MAX_HUNKS: usize = 10_000;
const MAX_DIFF_LINES: usize = 100_000;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReviewEvidence {
    pub schema: u32,
    pub evidence_complete: bool,
    pub base_commit: String,
    pub head_commit: String,
    pub protected_head_commit: String,
    pub changed_files: Vec<ChangedFileEvidence>,
    pub test_evidence: Vec<TestEvidence>,
    pub tool_evidence: Vec<ToolEvidence>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChangedFileEvidence {
    pub path: String,
    pub change_type: String,
    pub additions: u64,
    pub deletions: u64,
    pub hunks: Vec<DiffHunkEvidence>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiffHunkEvidence {
    pub old_start: u64,
    pub old_lines: u64,
    pub new_start: u64,
    pub new_lines: u64,
    pub header: String,
    pub lines: Vec<DiffLineEvidence>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiffLineEvidence {
    pub kind: String,
    pub content: String,
    pub old_line: Option<u64>,
    pub new_line: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TestEvidence {
    pub command: String,
    pub status: String,
    pub exit_code: u8,
    pub output_digest: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ToolEvidence {
    pub sequence: u16,
    pub tool: String,
    pub outcome: String,
}

impl ReviewEvidence {
    pub fn capture(
        projects: &ProjectManager,
        project: &ProjectView,
        worktree: &std::path::Path,
        base_commit: &str,
        mut tests: Vec<TestEvidence>,
        mut tools: Vec<ToolEvidence>,
    ) -> Result<Self, String> {
        let head_commit = projects.commit_at(worktree)?;
        let protected_head_commit = projects.protected_head(project)?;
        if protected_head_commit != base_commit {
            return Err("PROTECTED_HEAD_DRIFT: protected checkout moved before review".into());
        }
        if !projects.is_ancestor(worktree, base_commit, &head_commit)? {
            return Err("REVIEW_EVIDENCE_INVALID: reviewed head does not descend from base".into());
        }
        if !projects.status_at(worktree)?.is_empty() {
            return Err("REVIEW_EVIDENCE_STALE: worktree has uncommitted changes".into());
        }
        let changed_files = parse_changed_files(
            &projects.diff_name_status(worktree, base_commit, &head_commit)?,
            &projects.diff_numstat(worktree, base_commit, &head_commit)?,
            &projects.diff_patch(worktree, base_commit, &head_commit)?,
        )?;
        tests.sort_by(|left, right| left.command.cmp(&right.command));
        tools.sort_by_key(|item| item.sequence);
        let evidence_complete = !changed_files.is_empty()
            && !tests.is_empty()
            && tests.iter().all(|test| test.status == "passed")
            && !tools.is_empty();
        let evidence = Self {
            schema: REVIEW_EVIDENCE_SCHEMA,
            evidence_complete,
            base_commit: base_commit.to_owned(),
            head_commit,
            protected_head_commit,
            changed_files,
            test_evidence: tests,
            tool_evidence: tools,
        };
        evidence.validate_complete()?;
        Ok(evidence)
    }

    pub fn digest(&self) -> Result<String, String> {
        let canonical = serde_json::to_vec(self).map_err(|error| error.to_string())?;
        Ok(hex::encode(sha2::Sha256::digest(canonical)))
    }

    pub fn validate_complete(&self) -> Result<(), String> {
        if self.schema != REVIEW_EVIDENCE_SCHEMA
            || !self.evidence_complete
            || self.changed_files.is_empty()
            || self.test_evidence.is_empty()
            || self.tool_evidence.is_empty()
        {
            return Err("REVIEW_EVIDENCE_INCOMPLETE".into());
        }
        if self.test_evidence.iter().any(|test| {
            test.status != "passed" || test.exit_code != 0 || !is_sha256(&test.output_digest)
        }) {
            return Err("REVIEW_TESTS_FAILED".into());
        }
        if self
            .tool_evidence
            .iter()
            .enumerate()
            .any(|(index, tool)| tool.outcome != "ok" || usize::from(tool.sequence) != index + 1)
        {
            return Err("REVIEW_TOOL_EVIDENCE_FAILED".into());
        }
        if self.base_commit != self.protected_head_commit || self.base_commit == self.head_commit {
            return Err("REVIEW_EVIDENCE_INVALID: commit relationship is inconsistent".into());
        }
        for commit in [
            &self.base_commit,
            &self.head_commit,
            &self.protected_head_commit,
        ] {
            if !(40..=64).contains(&commit.len())
                || !commit
                    .chars()
                    .all(|character| character.is_ascii_hexdigit())
            {
                return Err("REVIEW_EVIDENCE_INVALID: commit is not an object id".into());
            }
        }
        Ok(())
    }

    pub fn verify_checkout(
        &self,
        projects: &ProjectManager,
        worktree: &std::path::Path,
    ) -> Result<(), String> {
        self.validate_complete()?;
        if projects.commit_at(worktree)? != self.head_commit
            || !projects.status_at(worktree)?.is_empty()
        {
            return Err("REVIEW_EVIDENCE_STALE: reviewed worktree changed".into());
        }
        if !projects.is_ancestor(worktree, &self.base_commit, &self.head_commit)? {
            return Err("REVIEW_EVIDENCE_STALE: reviewed history changed".into());
        }
        let changed_files = parse_changed_files(
            &projects.diff_name_status(worktree, &self.base_commit, &self.head_commit)?,
            &projects.diff_numstat(worktree, &self.base_commit, &self.head_commit)?,
            &projects.diff_patch(worktree, &self.base_commit, &self.head_commit)?,
        )?;
        if changed_files != self.changed_files {
            return Err("REVIEW_EVIDENCE_STALE: reviewed diff changed".into());
        }
        Ok(())
    }
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.chars().all(|character| character.is_ascii_hexdigit())
}

fn parse_changed_files(
    names: &str,
    numbers: &str,
    patch: &str,
) -> Result<Vec<ChangedFileEvidence>, String> {
    let mut counts = BTreeMap::<String, (u64, u64, bool)>::new();
    for record in numbers.split('\0').filter(|record| !record.is_empty()) {
        let mut fields = record.splitn(3, '\t');
        let additions = fields.next().ok_or("REVIEW_EVIDENCE_INVALID: numstat")?;
        let deletions = fields.next().ok_or("REVIEW_EVIDENCE_INVALID: numstat")?;
        let path = fields.next().ok_or("REVIEW_EVIDENCE_INVALID: numstat")?;
        validate_path(path)?;
        let binary = additions == "-" || deletions == "-";
        counts.insert(
            path.to_owned(),
            (
                additions.parse().unwrap_or(0),
                deletions.parse().unwrap_or(0),
                binary,
            ),
        );
    }

    let mut records = names.split('\0').filter(|record| !record.is_empty());
    let mut files = Vec::new();
    while let Some(status) = records.next() {
        let path = records
            .next()
            .ok_or("REVIEW_EVIDENCE_INVALID: name-status path missing")?;
        validate_path(path)?;
        if status.starts_with('R') || status.starts_with('C') {
            return Err(
                "REVIEW_EVIDENCE_INVALID: renames must be emitted without rename folding".into(),
            );
        }
        let (additions, deletions, binary) = counts.get(path).copied().unwrap_or_default();
        let change_type = if binary {
            "binary"
        } else {
            match status.chars().next() {
                Some('A') => "added",
                Some('M') => "modified",
                Some('D') => "deleted",
                _ => return Err(format!("REVIEW_EVIDENCE_INVALID: unknown status {status}")),
            }
        };
        files.push(ChangedFileEvidence {
            path: path.to_owned(),
            change_type: change_type.to_owned(),
            additions,
            deletions,
            hunks: Vec::new(),
        });
        if files.len() > MAX_CHANGED_FILES {
            return Err("REVIEW_EVIDENCE_TOO_LARGE: too many changed files".into());
        }
    }
    parse_patch_hunks(patch, &mut files)?;
    Ok(files)
}

fn parse_patch_hunks(patch: &str, files: &mut [ChangedFileEvidence]) -> Result<(), String> {
    let mut file_index: Option<usize> = None;
    let mut current_hunk: Option<DiffHunkEvidence> = None;
    let mut old_line = 0u64;
    let mut new_line = 0u64;
    let mut hunk_count = 0usize;
    let mut line_count = 0usize;

    for line in patch.lines() {
        if line.starts_with("diff --git ") {
            flush_hunk(files, file_index, &mut current_hunk)?;
            file_index = Some(file_index.map_or(0, |index| index + 1));
            if file_index.is_some_and(|index| index >= files.len()) {
                return Err("REVIEW_EVIDENCE_INVALID: patch has an unexpected file".into());
            }
            continue;
        }
        if let Some(header) = line.strip_prefix("@@ ") {
            flush_hunk(files, file_index, &mut current_hunk)?;
            let (old_start, old_lines, new_start, new_lines) = parse_hunk_header(header)?;
            old_line = old_start;
            new_line = new_start;
            current_hunk = Some(DiffHunkEvidence {
                old_start,
                old_lines,
                new_start,
                new_lines,
                header: line.to_owned(),
                lines: Vec::new(),
            });
            hunk_count += 1;
            if hunk_count > MAX_HUNKS {
                return Err("REVIEW_EVIDENCE_TOO_LARGE: too many diff hunks".into());
            }
            continue;
        }
        let Some(hunk) = current_hunk.as_mut() else {
            continue;
        };
        let (kind, content, old_at, new_at) = if let Some(content) = line.strip_prefix('+') {
            let at = new_line;
            new_line += 1;
            ("addition", content, None, Some(at))
        } else if let Some(content) = line.strip_prefix('-') {
            let at = old_line;
            old_line += 1;
            ("deletion", content, Some(at), None)
        } else if let Some(content) = line.strip_prefix(' ') {
            let old_at = old_line;
            let new_at = new_line;
            old_line += 1;
            new_line += 1;
            ("context", content, Some(old_at), Some(new_at))
        } else if line == "\\ No newline at end of file" {
            continue;
        } else {
            return Err("REVIEW_EVIDENCE_INVALID: malformed diff line".into());
        };
        if content.len() > 16_384 {
            return Err("REVIEW_EVIDENCE_TOO_LARGE: diff line exceeds 16 KiB".into());
        }
        hunk.lines.push(DiffLineEvidence {
            kind: kind.to_owned(),
            content: content.to_owned(),
            old_line: old_at,
            new_line: new_at,
        });
        line_count += 1;
        if line_count > MAX_DIFF_LINES {
            return Err("REVIEW_EVIDENCE_TOO_LARGE: too many diff lines".into());
        }
    }
    flush_hunk(files, file_index, &mut current_hunk)?;
    if !files.is_empty() && file_index.map(|index| index + 1) != Some(files.len()) {
        return Err("REVIEW_EVIDENCE_INVALID: patch did not cover every changed file".into());
    }
    Ok(())
}

fn flush_hunk(
    files: &mut [ChangedFileEvidence],
    file_index: Option<usize>,
    hunk: &mut Option<DiffHunkEvidence>,
) -> Result<(), String> {
    if let Some(hunk) = hunk.take() {
        let index = file_index.ok_or("REVIEW_EVIDENCE_INVALID: hunk has no file")?;
        files[index].hunks.push(hunk);
    }
    Ok(())
}

fn parse_hunk_header(header: &str) -> Result<(u64, u64, u64, u64), String> {
    let mut fields = header.split_whitespace();
    let old = fields.next().ok_or("REVIEW_EVIDENCE_INVALID: old range")?;
    let new = fields.next().ok_or("REVIEW_EVIDENCE_INVALID: new range")?;
    if fields.next() != Some("@@") {
        return Err("REVIEW_EVIDENCE_INVALID: hunk terminator".into());
    }
    let (old_start, old_lines) = parse_range(old, '-')?;
    let (new_start, new_lines) = parse_range(new, '+')?;
    Ok((old_start, old_lines, new_start, new_lines))
}

fn parse_range(value: &str, prefix: char) -> Result<(u64, u64), String> {
    let range = value
        .strip_prefix(prefix)
        .ok_or("REVIEW_EVIDENCE_INVALID: hunk range prefix")?;
    let (start, lines) = range.split_once(',').unwrap_or((range, "1"));
    Ok((
        start
            .parse()
            .map_err(|_| "REVIEW_EVIDENCE_INVALID: hunk start")?,
        lines
            .parse()
            .map_err(|_| "REVIEW_EVIDENCE_INVALID: hunk length")?,
    ))
}

fn validate_path(path: &str) -> Result<(), String> {
    if path.is_empty()
        || path.len() > 4096
        || path.starts_with('/')
        || path.contains('\0')
        || std::path::Path::new(path)
            .components()
            .any(|part| !matches!(part, std::path::Component::Normal(_)))
    {
        return Err(format!(
            "REVIEW_EVIDENCE_INVALID: unsafe changed path {path:?}"
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_changed_paths_and_hunks() {
        let files = parse_changed_files(
            "M\0src/lib.rs\0",
            "2\t1\tsrc/lib.rs\0",
            "diff --git a/src/lib.rs b/src/lib.rs\n--- a/src/lib.rs\n+++ b/src/lib.rs\n@@ -1,2 +1,3 @@ fn value\n old\n-gone\n+new\n+more\n",
        )
        .unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].path, "src/lib.rs");
        assert_eq!(files[0].hunks[0].lines[1].kind, "deletion");
        assert_eq!(files[0].hunks[0].lines[2].new_line, Some(2));
    }

    #[test]
    fn complete_evidence_rejects_missing_or_failed_tests() {
        let mut evidence = ReviewEvidence {
            schema: REVIEW_EVIDENCE_SCHEMA,
            evidence_complete: true,
            base_commit: "a".repeat(40),
            head_commit: "b".repeat(40),
            protected_head_commit: "a".repeat(40),
            changed_files: vec![ChangedFileEvidence {
                path: "file".into(),
                change_type: "added".into(),
                additions: 1,
                deletions: 0,
                hunks: Vec::new(),
            }],
            test_evidence: Vec::new(),
            tool_evidence: vec![ToolEvidence {
                sequence: 1,
                tool: "write_file".into(),
                outcome: "ok".into(),
            }],
        };
        assert_eq!(
            evidence.validate_complete().unwrap_err(),
            "REVIEW_EVIDENCE_INCOMPLETE"
        );
        evidence.test_evidence.push(TestEvidence {
            command: "cargo test".into(),
            status: "failed".into(),
            exit_code: 1,
            output_digest: "c".repeat(64),
        });
        assert_eq!(
            evidence.validate_complete().unwrap_err(),
            "REVIEW_TESTS_FAILED"
        );
    }
}
