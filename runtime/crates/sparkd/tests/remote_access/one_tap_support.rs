/// Script the privileged helper's view of Tailscale so no test touches a real tailnet.
struct ScriptedProvisioner {
    signed_in: std::sync::atomic::AtomicBool,
    installable: bool,
    prepare_calls: std::sync::atomic::AtomicUsize,
    /// What the enable asked to undo, in the order it asked.
    rollbacks: Mutex<Vec<OverlayRollback>>,
    /// Named states a rollback cannot clear, so a failed rollback can be exercised.
    stuck: Vec<String>,
}

impl ScriptedProvisioner {
    fn signed_out() -> Self {
        Self {
            signed_in: std::sync::atomic::AtomicBool::new(false),
            installable: true,
            prepare_calls: std::sync::atomic::AtomicUsize::new(0),
            rollbacks: Mutex::new(Vec::new()),
            stuck: Vec::new(),
        }
    }

    /// A Spark whose Tailscale client refuses to sign out again.
    fn signed_out_and_stuck() -> Self {
        Self {
            stuck: vec!["signed_in".to_owned()],
            ..Self::signed_out()
        }
    }

    fn not_installable() -> Self {
        Self {
            signed_in: std::sync::atomic::AtomicBool::new(false),
            installable: false,
            prepare_calls: std::sync::atomic::AtomicUsize::new(0),
            rollbacks: Mutex::new(Vec::new()),
            stuck: Vec::new(),
        }
    }

    fn rollbacks(&self) -> Vec<OverlayRollback> {
        self.rollbacks.lock().clone()
    }

    fn owner_signed_in(&self) {
        self.signed_in
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    fn prepare_calls(&self) -> usize {
        self.prepare_calls.load(std::sync::atomic::Ordering::SeqCst)
    }

    fn setup(&self, with_link: bool) -> OverlaySetup {
        if !self.installable {
            return OverlaySetup {
                state: OverlaySetupState::NotInstalled,
                installable: Some(false),
                ..OverlaySetup::tailscale()
            };
        }
        if self.signed_in.load(std::sync::atomic::Ordering::SeqCst) {
            return OverlaySetup {
                state: OverlaySetupState::Ready,
                hostname: Some("spark-example.tail1234.ts.net".into()),
                address: Some("100.96.4.2".into()),
                tailnet: Some("tail1234.ts.net".into()),
                created_service: Some(true),
                attempted_login: Some(true),
                ..OverlaySetup::tailscale()
            };
        }
        OverlaySetup {
            state: OverlaySetupState::LoginRequired,
            authorization_url: with_link
                .then(|| "https://login.tailscale.com/a/0123456789abcdef".to_owned()),
            created_service: Some(true),
            attempted_login: Some(true),
            ..OverlaySetup::tailscale()
        }
    }
}

impl PrivateOverlayProvisioner for ScriptedProvisioner {
    fn prepare(&self) -> Result<OverlaySetup, String> {
        self.prepare_calls
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        if !self.installable {
            return Err("Tailscale is not installed and cannot be installed here".into());
        }
        self.signed_in
            .load(std::sync::atomic::Ordering::SeqCst)
            .then(|| self.setup(false))
            .map(Ok)
            .unwrap_or_else(|| Ok(self.setup(true)))
    }

    fn status(&self) -> Result<OverlaySetup, String> {
        // The CLI keeps reporting the link once `up` has requested it.
        Ok(self.setup(self.prepare_calls() > 0))
    }

    fn roll_back(&self, undo: OverlayRollback) -> Result<OverlayRollbackReport, String> {
        self.rollbacks.lock().push(undo);
        if self.stuck.is_empty() {
            self.signed_in
                .store(false, std::sync::atomic::Ordering::SeqCst);
        }
        Ok(OverlayRollbackReport {
            logged_out: undo.logout && self.stuck.is_empty(),
            service_disabled: undo.disable_service && self.stuck.is_empty(),
            remaining: self.stuck.clone(),
        })
    }
}

/// A state whose remote service provisions through the scripted helper with a short sign-in window.
async fn one_tap_state(
    role: &'static str,
    provisioner: Arc<ScriptedProvisioner>,
) -> (
    AppState,
    TestClient,
    Arc<Mutex<Connection>>,
    tempfile::TempDir,
) {
    let (base, client, database, guard) = test_state(role);
    let dynamic: Arc<dyn PrivateOverlayProvisioner> = provisioner;
    let service = RemoteAccessService::new(database.clone(), base.events.clone(), base.identity.node_id().to_string())
    .with_private_overlay_probe(Arc::new(ProvisionedOverlayProbe::without_self_probe(
        dynamic.clone(),
    )))
    .with_private_overlay_provisioner(dynamic)
    .with_overlay_sign_in_window(Duration::from_millis(400), Duration::from_millis(20));
    let state = base.with_remote(Arc::new(service));
    (state, client, database, guard)
}

fn wait_for_stage(database: &Arc<Mutex<Connection>>, operation_id: &str, stage: &str) -> String {
    let mut last = String::new();
    for _ in 0..100 {
        std::thread::sleep(Duration::from_millis(10));
        let current = database
            .lock()
            .query_row(
                "SELECT COALESCE(stage, ''), state FROM operations WHERE id = ?1",
                [operation_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .ok();
        if let Some((current_stage, state)) = current {
            last = current_stage.clone();
            if current_stage == stage {
                return current_stage;
            }
            if !matches!(state.as_str(), "requested" | "queued" | "running") {
                return format!("{state}:{current_stage}");
            }
        }
    }
    last
}
