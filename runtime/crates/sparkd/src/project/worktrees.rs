use super::*;

pub(super) struct Worktrees<'a> {
    pub(super) git: &'a dyn GitRunner,
    pub(super) containers: &'a dyn ContainerBoundary,
    pub(super) db: &'a Mutex<rusqlite::Connection>,
    pub(super) worktrees_root: &'a Path,
    pub(super) locks: &'a coordination::ProjectLocks,
    pub(super) previews: &'a coordination::PreviewPorts,
}

impl Worktrees<'_> {
    /// Load the validated dev-container plan for a project (if any).
    pub fn devcontainer_plan(
        &self,
        project: &ProjectView,
    ) -> Result<Option<DevcontainerPlan>, String> {
        match spark_project_runner::load_plan(&project.root_path) {
            Ok(plan) => Ok(Some(plan)),
            Err(spark_project_runner::DevcontainerError::Missing(_)) => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    /// Create an agent worktree and validated container, binding any supplied durable operation ID.
    pub fn create_worktree(
        &self,
        project: &ProjectView,
        base_commit: Option<&str>,
        operation_id: Option<Uuid>,
    ) -> Result<CreatedWorktree, String> {
        self.create_worktree_using_plan(project, base_commit, operation_id, None, true)
    }

    pub(super) fn create_worktree_using_plan(
        &self,
        project: &ProjectView,
        base_commit: Option<&str>,
        operation_id: Option<Uuid>,
        plan: Option<DevcontainerPlan>,
        start_container: bool,
    ) -> Result<CreatedWorktree, String> {
        let base = match base_commit {
            Some(commit) => commit.to_owned(),
            None => self
                .git
                .run(&project.root_path, &["rev-parse", "HEAD"])
                .map_err(|e| e.to_string())?,
        };
        let wt_id = Uuid::new_v4();
        let branch_id = operation_id.unwrap_or(wt_id);
        let branch = agent_branch_name(branch_id);
        let path = create_agent_worktree(
            self.git,
            &project.root_path,
            self.worktrees_root,
            branch_id,
            &base,
        )
        .map_err(|e| e.to_string())?;
        {
            let conn = self.db.lock();
            store::insert_worktree(
                &conn,
                &wt_id,
                &project.id,
                operation_id.as_ref(),
                &path.display().to_string(),
                &base,
                &branch,
            )
            .map_err(|e| e.to_string())?;
            store::update_worktree_state(&conn, &wt_id, "active").map_err(|e| e.to_string())?;
        }
        // Prepare the validated dev container for this worktree when configured.
        let container = if !start_container {
            None
        } else {
            match plan
                .map(Some)
                .map(Ok)
                .unwrap_or_else(|| self.devcontainer_plan(project))
            {
                Ok(Some(plan)) => {
                    let running = self
                        .containers
                        .start(&plan, project.id, &path)
                        .map_err(|e| e.to_string())?;
                    for port in &running.forward_ports {
                        self.previews
                            .register_preview_port(&project.id, *port, &running.id);
                    }
                    Some(running)
                }
                Ok(None) => None,
                Err(e) => return Err(e),
            }
        };
        Ok(CreatedWorktree {
            id: wt_id,
            path,
            branch,
            base_commit: base,
            container,
        })
    }

    pub fn commit_at(&self, checkout: &Path) -> Result<String, String> {
        self.git.run_isolated(checkout, &["rev-parse", "HEAD"])
    }

    pub fn protected_head(&self, project: &ProjectView) -> Result<String, String> {
        self.commit_at(&project.root_path)
    }

    pub fn status_at(&self, checkout: &Path) -> Result<String, String> {
        self.git.run_isolated(
            checkout,
            &["status", "--porcelain=v1", "--untracked-files=all"],
        )
    }

    pub fn is_ancestor(&self, checkout: &Path, base: &str, head: &str) -> Result<bool, String> {
        match self
            .git
            .run_isolated(checkout, &["merge-base", "--is-ancestor", base, head])
        {
            Ok(_) => Ok(true),
            Err(error) if error.is_empty() => Ok(false),
            Err(_) => Ok(false),
        }
    }

    pub fn diff_name_status(
        &self,
        checkout: &Path,
        base: &str,
        head: &str,
    ) -> Result<String, String> {
        self.git.run_isolated(
            checkout,
            &[
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--name-status",
                "-z",
                "--no-renames",
                base,
                head,
            ],
        )
    }

    pub fn diff_numstat(&self, checkout: &Path, base: &str, head: &str) -> Result<String, String> {
        self.git.run_isolated(
            checkout,
            &[
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--numstat",
                "-z",
                base,
                head,
            ],
        )
    }

    pub fn diff_patch(&self, checkout: &Path, base: &str, head: &str) -> Result<String, String> {
        let patch = self.git.run_isolated(
            checkout,
            &[
                "diff",
                "--no-ext-diff",
                "--no-textconv",
                "--no-color",
                "--no-renames",
                "--unified=3",
                base,
                head,
            ],
        )?;
        if patch.len() >= spark_project_runner::GIT_OUTPUT_CAP {
            return Err("REVIEW_EVIDENCE_TOO_LARGE: diff reached the capture limit".into());
        }
        Ok(patch)
    }

    pub fn worktree_path_for_branch(&self, branch: &str) -> Result<PathBuf, String> {
        safe_worktree_path(self.worktrees_root, branch).map_err(|error| error.to_string())
    }

    /// Merge exact reviewed heads and reconcile an applied retry without creating another commit.
    pub fn merge_reviewed_worktree(
        &self,
        project: &ProjectView,
        review: &ReviewedMerge<'_>,
    ) -> Result<String, String> {
        let lock = self.locks.lock_for(project.id);
        let _guard = lock.lock();
        let worktree = self.worktree_path_for_branch(review.branch)?;
        if self.commit_at(&worktree)? != review.reviewed_head
            || !self.status_at(&worktree)?.is_empty()
        {
            return Err("REVIEW_EVIDENCE_STALE: reviewed worktree changed".into());
        }
        let protected_head = self.protected_head(project)?;
        if protected_head != review.reviewed_protected_head {
            let protected_tree = self.git.run(
                &project.root_path,
                &["rev-parse", &format!("{protected_head}^{{tree}}")],
            )?;
            let reviewed_tree = self.git.run_isolated(
                &worktree,
                &["rev-parse", &format!("{}^{{tree}}", review.reviewed_head)],
            )?;
            let protected_parent = self.git.run(
                &project.root_path,
                &["rev-parse", &format!("{protected_head}^")],
            )?;
            let protected_message = self.git.run(
                &project.root_path,
                &["log", "-1", "--format=%B", &protected_head],
            )?;
            let digest_trailer = format!("Spark-Review-Digest: {}", review.review_digest);
            if protected_tree == reviewed_tree
                && protected_parent == review.reviewed_protected_head
                && protected_message
                    .lines()
                    .any(|line| line.trim() == digest_trailer)
            {
                return Ok(protected_head);
            }
            return Err("PROTECTED_HEAD_DRIFT: protected checkout moved after review".into());
        }
        self.git.import_reviewed(
            &project.root_path,
            &worktree,
            review.reviewed_head,
            review.branch,
        )?;
        squash_merge(
            self.git,
            &project.root_path,
            review.branch,
            review.message,
            review.author,
        )
        .map_err(|error| error.to_string())?;
        self.protected_head(project)
    }

    pub fn worktree_list(&self, project: &ProjectView) -> Result<Vec<String>, String> {
        let conn = self.db.lock();
        let mut statement = conn.prepare("SELECT path FROM project_worktrees WHERE project_id = ?1 AND state != 'deleted' ORDER BY created_at").map_err(|error| error.to_string())?;
        statement
            .query_map([project.id.to_string()], |row| row.get::<_, String>(0))
            .map_err(|error| error.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| error.to_string())
    }

    pub fn worktree_status(&self, project: &ProjectView) -> Result<String, String> {
        status_porcelain(self.git, &project.root_path).map_err(|e| e.to_string())
    }

    pub fn merge_worktree(
        &self,
        project: &ProjectView,
        branch: &str,
        message: &str,
        author: &str,
    ) -> Result<(), String> {
        let worktree = self.worktree_path_for_branch(branch)?;
        let head = self.commit_at(&worktree)?;
        self.git
            .import_reviewed(&project.root_path, &worktree, &head, branch)?;
        squash_merge(self.git, &project.root_path, branch, message, author)
            .map_err(|e| e.to_string())
    }

    pub fn remove_worktree(&self, project: &ProjectView, path: &Path) -> Result<(), String> {
        let path_text = path.display().to_string();
        let registered: bool = self.db.lock().query_row("SELECT EXISTS(SELECT 1 FROM project_worktrees WHERE project_id = ?1 AND path = ?2 AND state != 'deleted')", rusqlite::params![project.id.to_string(), path_text], |row| row.get(0)).map_err(|error| error.to_string())?;
        if !registered {
            return Err("WORKTREE_NOT_FOUND".into());
        }
        remove_worktree(self.git, &project.root_path, self.worktrees_root, path)
            .map_err(|error| error.to_string())?;
        self.db.lock().execute("UPDATE project_worktrees SET state = 'deleted' WHERE project_id = ?1 AND path = ?2", rusqlite::params![project.id.to_string(), path_text]).map_err(|error| error.to_string())?;
        // The container named after this worktree goes with it; forget its preview ports.
        if let Some(worktree_id) = path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_prefix("agent-"))
        {
            self.previews
                .unregister_container(&project.id, &format!("spark-project-{worktree_id}"));
        }
        Ok(())
    }
}
