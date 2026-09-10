#[test]
fn expired_network_rollback_runs_and_deletes_its_journal() {
    struct PausedRollbackRunner {
        recording: Arc<RecordingRunner>,
        started: std::sync::mpsc::SyncSender<()>,
        release: Mutex<std::sync::mpsc::Receiver<()>>,
    }

    impl CommandRunner for PausedRollbackRunner {
        fn run(&self, program: &str, args: &[String]) -> Result<CommandOutput, String> {
            if program == NMCLI_BIN && args == ["connection", "delete", "id", "Main WiFi"] {
                self.started.send(()).map_err(|error| error.to_string())?;
                self.release
                    .lock()
                    .unwrap()
                    .recv()
                    .map_err(|error| error.to_string())?;
            }
            self.recording.run(program, args)
        }

        fn run_with_secret_input(
            &self,
            program: &str,
            args: &[String],
            secret: &str,
        ) -> Result<CommandOutput, String> {
            self.recording.run_with_secret_input(program, args, secret)
        }
    }

    let root = tempfile::tempdir().unwrap();
    let journal_directory = root.path().join("network-rollbacks");
    let runner = Arc::new(RecordingRunner::new());
    let previous_wifi = Uuid::new_v4();
    runner.ok(Some(0), &format!("{previous_wifi}:802-11-wireless\n"), "");
    runner.ok(Some(1), "", "unknown connection");
    runner.ok(Some(0), "activated\n", "");
    runner.ok(Some(0), "removed\n", "");
    runner.ok(Some(0), "restored\n", "");
    let (started, rollback_started) = std::sync::mpsc::sync_channel(0);
    let (release_rollback, release) = std::sync::mpsc::sync_channel(0);
    let paused_runner = Arc::new(PausedRollbackRunner {
        recording: runner.clone(),
        started,
        release: Mutex::new(release),
    });
    let backend = DockerBackend::new("docker", false)
        .with_network_rollback_timeout(Duration::from_millis(25))
        .with_appliance_command_runner(paused_runner)
        .with_network_rollback_journal_dir(&journal_directory);
    backend
        .execute(&PrivilegedOperation::ConnectWifi {
            request_id: Uuid::new_v4(),
            ssid: "Main WiFi".into(),
            passphrase: None,
            hidden: false,
        })
        .unwrap();
    let journal_path = journal_directory.join(NETWORK_ROLLBACK_JOURNAL_FILE);
    rollback_started
        .recv_timeout(Duration::from_secs(2))
        .expect("the expired rollback did not start");
    // Hold rollback completion so journal observation cannot race the 25 ms expiry.
    assert!(journal_path.is_file());
    release_rollback.send(()).unwrap();

    for _ in 0..100 {
        if !journal_path.exists() && runner.calls().len() == 5 {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    assert!(!journal_path.exists());
    assert_eq!(runner.calls().len(), 5);
}
