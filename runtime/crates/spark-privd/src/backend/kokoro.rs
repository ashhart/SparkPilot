use super::*;
use crate::kokoro::{CONTAINER, IMAGE, PORT, PREVIOUS};
use crate::protocol::KokoroAction;

static MUTATION: std::sync::Mutex<()> = std::sync::Mutex::new(());

impl DockerBackend {
    fn kokoro_command(&self, args: Vec<String>) -> Result<(), BackendError> {
        let output = self.run_appliance(&self.docker_bin, args, None)?;
        if output.success() {
            Ok(())
        } else {
            Err(BackendError::Failure(
                "Kokoro container command failed".into(),
            ))
        }
    }

    fn inspect_kokoro(&self, name: &str) -> Result<Option<(bool, String, bool)>, BackendError> {
        let output =
            self.run_appliance(&self.docker_bin, vec!["inspect".into(), name.into()], None)?;
        if !output.success() {
            if docker_reports_missing_container(&output.stderr) {
                return Ok(None);
            }
            return Err(BackendError::Failure("Kokoro status is unavailable".into()));
        }
        let values: Vec<serde_json::Value> = serde_json::from_slice(&output.stdout)
            .map_err(|_| BackendError::Failure("Kokoro container inspection is invalid".into()))?;
        let value = values
            .first()
            .ok_or_else(|| BackendError::Failure("Kokoro inspection is empty".into()))?;
        let image = value["Config"]["Image"].as_str().unwrap_or("");
        if value["Config"]["Labels"]["spark.service"] != "kokoro"
            || !image.starts_with("ghcr.io/remsky/kokoro-fastapi-gpu@sha256:")
            || !valid_pinned_image(image)
        {
            return Err(BackendError::Failure(
                "An unmanaged container occupies the Kokoro service name".into(),
            ));
        }
        Ok(Some((
            value["State"]["Running"].as_bool().unwrap_or(false),
            image.into(),
            value["HostConfig"]["Dns"] == serde_json::json!(["127.0.0.1"]),
        )))
    }

    fn kokoro_healthy(&self) -> bool {
        #[cfg(test)]
        if let Some(probe) = &self.kokoro_probe {
            return probe();
        }
        let address = SocketAddr::from(([127, 0, 0, 1], PORT));
        let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_millis(300))
        else {
            return false;
        };
        let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(1)));
        if stream
            .write_all(b"GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            .is_err()
        {
            return false;
        }
        let mut bytes = [0; 128];
        let Ok(count) = stream.read(&mut bytes) else {
            return false;
        };
        bytes[..count].starts_with(b"HTTP/1.1 200") || bytes[..count].starts_with(b"HTTP/1.0 200")
    }

    fn wait_for_kokoro(&self) -> bool {
        #[cfg(test)]
        if let Some(probe) = &self.kokoro_probe {
            return probe();
        }
        let deadline = Instant::now() + Duration::from_secs(120);
        while Instant::now() < deadline {
            if self.kokoro_healthy() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        false
    }

    pub(super) fn execute_kokoro(
        &self,
        operation: &PrivilegedOperation,
    ) -> Result<PrivilegedResponse, BackendError> {
        let PrivilegedOperation::KokoroService { request_id, action } = operation else {
            unreachable!()
        };
        let reply = |accepted, code: &str, details| PrivilegedResponse {
            request_id: *request_id,
            accepted,
            code: code.into(),
            message: "Kokoro service operation".into(),
            details,
        };
        if self.plan_only {
            return Ok(reply(
                true,
                "planned",
                serde_json::json!({"argv":crate::kokoro::launch_args(IMAGE)}),
            ));
        }
        if *action == KokoroAction::Status {
            let current = self.inspect_kokoro(CONTAINER)?;
            return Ok(reply(
                true,
                "kokoro_status",
                serde_json::json!({
                    "installed":current.is_some(),"running":current.as_ref().is_some_and(|v|v.0),
                    "healthy":current.as_ref().is_some_and(|v|v.0) && self.kokoro_healthy(),
                    "image":current.map(|v|v.1),
                }),
            ));
        }
        let _guard = MUTATION
            .lock()
            .map_err(|_| BackendError::Failure("Kokoro operation lock is unavailable".into()))?;
        let mut current = self.inspect_kokoro(CONTAINER)?;
        // A helper restart between rename and launch recovers the prior release.
        if current.is_none() && self.inspect_kokoro(PREVIOUS)?.is_some() {
            self.kokoro_command(vec!["rename".into(), PREVIOUS.into(), CONTAINER.into()])?;
            current = self.inspect_kokoro(CONTAINER)?;
            if current.as_ref().is_some_and(|v| v.2) {
                self.kokoro_command(vec!["start".into(), CONTAINER.into()])?;
                current = self.inspect_kokoro(CONTAINER)?;
            }
        }
        if matches!(action, KokoroAction::Enable | KokoroAction::Disable)
            && (*action == KokoroAction::Disable || current.as_ref().is_none_or(|v| v.2))
        {
            let Some((running, _, _)) = current else {
                return Ok(reply(
                    false,
                    "KOKORO_NOT_INSTALLED",
                    serde_json::Value::Null,
                ));
            };
            let enable = *action == KokoroAction::Enable;
            // Persist disabled state across Docker/host restarts, retaining the image.
            self.kokoro_command(vec![
                "update".into(),
                "--restart".into(),
                if enable { "unless-stopped" } else { "no" }.into(),
                CONTAINER.into(),
            ])?;
            if enable && !running {
                self.kokoro_command(vec!["start".into(), CONTAINER.into()])?;
            }
            if !enable && running {
                self.kokoro_command(vec![
                    "stop".into(),
                    "--time".into(),
                    "20".into(),
                    CONTAINER.into(),
                ])?;
            }
            let healthy = enable && self.wait_for_kokoro();
            return Ok(reply(
                !enable || healthy,
                if enable && !healthy {
                    "KOKORO_START_FAILED"
                } else {
                    "kokoro_changed"
                },
                serde_json::json!({"running":enable,"healthy":healthy}),
            ));
        }
        if *action == KokoroAction::Remove {
            if current.is_some() {
                self.kokoro_command(vec!["rm".into(), "-f".into(), CONTAINER.into()])?;
            }
            if self.inspect_kokoro(PREVIOUS)?.is_some() {
                self.kokoro_command(vec!["rm".into(), "-f".into(), PREVIOUS.into()])?;
            }
            return Ok(reply(
                true,
                "kokoro_removed",
                serde_json::json!({"installed":false}),
            ));
        }
        if let Some((running, image, isolated)) = &current {
            if image == IMAGE && *isolated {
                if !running && *action == KokoroAction::Update {
                    return Ok(reply(
                        true,
                        "kokoro_current",
                        serde_json::json!({"image":IMAGE}),
                    ));
                }
                if !running {
                    self.kokoro_command(vec!["start".into(), CONTAINER.into()])?;
                }
                return Ok(reply(
                    self.wait_for_kokoro(),
                    "kokoro_ready",
                    serde_json::json!({"image":IMAGE}),
                ));
            }
        } else if *action == KokoroAction::Update {
            return Ok(reply(
                false,
                "KOKORO_NOT_INSTALLED",
                serde_json::Value::Null,
            ));
        }
        self.pull_image(IMAGE)?;
        self.ensure_inference_isolated_network()?;
        if self.inspect_kokoro(PREVIOUS)?.is_some() {
            self.kokoro_command(vec!["rm".into(), "-f".into(), PREVIOUS.into()])?;
        }
        if current.is_some() {
            self.kokoro_command(vec![
                "stop".into(),
                "--time".into(),
                "20".into(),
                CONTAINER.into(),
            ])?;
            self.kokoro_command(vec!["rename".into(), CONTAINER.into(), PREVIOUS.into()])?;
        }
        let keep_disabled = *action != KokoroAction::Enable
            && current.as_ref().is_some_and(|(running, _, _)| !running);
        let launched = self
            .kokoro_command(crate::kokoro::launch_args(IMAGE))
            .is_ok();
        if launched && self.wait_for_kokoro() {
            if keep_disabled {
                self.kokoro_command(vec![
                    "update".into(),
                    "--restart".into(),
                    "no".into(),
                    CONTAINER.into(),
                ])?;
                self.kokoro_command(vec!["stop".into(), CONTAINER.into()])?;
            }
            if current.is_some() {
                self.kokoro_command(vec!["rm".into(), PREVIOUS.into()])?;
            }
            return Ok(reply(
                true,
                "kokoro_ready",
                serde_json::json!({"image":IMAGE}),
            ));
        }
        if self.inspect_kokoro(CONTAINER)?.is_some() {
            self.kokoro_command(vec!["rm".into(), "-f".into(), CONTAINER.into()])?;
        }
        if current.is_some() {
            self.kokoro_command(vec!["rename".into(), PREVIOUS.into(), CONTAINER.into()])?;
            let healthy = if keep_disabled || current.as_ref().is_some_and(|v| !v.2) {
                false
            } else {
                self.kokoro_command(vec!["start".into(), CONTAINER.into()])?;
                self.wait_for_kokoro()
            };
            return Ok(reply(
                false,
                "KOKORO_UPDATE_ROLLED_BACK",
                serde_json::json!({"healthy":healthy}),
            ));
        }
        Ok(reply(false, "KOKORO_START_FAILED", serde_json::Value::Null))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::update::CommandOutput;
    use std::{
        collections::BTreeMap,
        os::unix::fs::PermissionsExt,
        sync::{Arc, Mutex},
    };
    struct Runner {
        containers: Mutex<BTreeMap<String, (bool, String)>>,
        calls: Mutex<Vec<Vec<String>>>,
        fail_launch: bool,
        foreign: bool,
        legacy_dns: std::sync::atomic::AtomicBool,
    }
    impl CommandRunner for Runner {
        fn run_with_secret_input(
            &self,
            _: &str,
            _: &[String],
            _: &str,
        ) -> Result<CommandOutput, String> {
            panic!("Kokoro must never need credentials")
        }
        fn run(&self, _: &str, args: &[String]) -> Result<CommandOutput, String> {
            self.calls.lock().unwrap().push(args.to_vec());
            let mut containers = self.containers.lock().unwrap();
            let mut output = CommandOutput {
                status: Some(0),
                stdout: vec![],
                stderr: vec![],
            };
            match args[0].as_str() {
                "--json" => {
                    output.stdout =
                        serde_json::to_vec(&inference_firewall::test_evidence()).unwrap();
                }
                "inspect" => {
                    if let Some((running, image)) = containers.get(&args[1]) {
                        output.stdout=serde_json::to_vec(&serde_json::json!([{"Config":{"Image":image,"Labels":{"spark.service":if self.foreign {"foreign"} else {"kokoro"}}},"State":{"Running":running},"HostConfig":{"Dns":if self.legacy_dns.load(std::sync::atomic::Ordering::Relaxed) { vec![] } else { vec!["127.0.0.1"] }}}])).unwrap();
                    } else {
                        output.status = Some(1);
                        output.stderr = b"No such object: container".to_vec();
                    }
                }
                "stop" | "start" => {
                    containers.get_mut(args.last().unwrap()).unwrap().0 = args[0] == "start";
                }
                "rename" => {
                    let value = containers.remove(&args[1]).unwrap();
                    containers.insert(args[2].clone(), value);
                }
                "rm" => {
                    containers.remove(args.last().unwrap());
                }
                "run" => {
                    if self.fail_launch {
                        output.status = Some(1);
                    } else {
                        self.legacy_dns
                            .store(false, std::sync::atomic::Ordering::Relaxed);
                        containers.insert(CONTAINER.into(), (true, IMAGE.into()));
                    }
                }
                "update" => {}
                _ => panic!("unexpected command {args:?}"),
            }
            Ok(output)
        }
    }
    fn fixture(
        running: bool,
        fail_launch: bool,
        foreign: bool,
    ) -> (tempfile::TempDir, DockerBackend, Arc<Runner>, String) {
        let dir = tempfile::tempdir().unwrap();
        let docker = dir.path().join("docker");
        let network = serde_json::json!([{"Name":"spark-inference-isolated","Id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","Driver":"bridge","Scope":"local","Internal":false,"Attachable":false,"Ingress":false,"EnableIPv6":false,"Options":{"com.docker.network.bridge.enable_ip_masquerade":"false","com.docker.network.bridge.enable_icc":"false","com.docker.network.bridge.host_binding_ipv4":"127.0.0.1"}}]);
        fs::write(
            &docker,
            format!(
                "#!/bin/sh\nif [ \"$1\" = pull ]; then exit 0; fi\nprintf '%s\\n' '{network}'\n"
            ),
        )
        .unwrap();
        fs::set_permissions(&docker, fs::Permissions::from_mode(0o700)).unwrap();
        let old = format!(
            "ghcr.io/remsky/kokoro-fastapi-gpu@sha256:{}",
            "a".repeat(64)
        );
        let runner = Arc::new(Runner {
            containers: Mutex::new(BTreeMap::from([(CONTAINER.into(), (running, old.clone()))])),
            calls: Mutex::new(vec![]),
            fail_launch,
            foreign,
            legacy_dns: std::sync::atomic::AtomicBool::new(false),
        });
        let mut backend = DockerBackend::new(docker.to_string_lossy(), true)
            .with_appliance_command_runner(runner.clone());
        backend.plan_only = false;
        backend.kokoro_probe = Some(Arc::new(|| true));
        (dir, backend, runner, old)
    }
    fn run(
        backend: &DockerBackend,
        action: KokoroAction,
    ) -> Result<PrivilegedResponse, BackendError> {
        backend.execute_kokoro(&PrivilegedOperation::KokoroService {
            request_id: uuid::Uuid::new_v4(),
            action,
        })
    }
    #[test]
    fn failed_kokoro_replacement_restores_the_old_container() {
        let (_dir, backend, runner, old) = fixture(true, true, false);
        let result = run(&backend, KokoroAction::Update).unwrap();
        assert!(!result.accepted);
        assert_eq!(result.code, "KOKORO_UPDATE_ROLLED_BACK");
        assert_eq!(
            runner.containers.lock().unwrap().get(CONTAINER),
            Some(&(true, old))
        );
        assert!(!runner.containers.lock().unwrap().contains_key(PREVIOUS));
    }
    #[test]
    fn kokoro_update_preserves_disabled_state_and_disable_retains_downloads() {
        let (_dir, backend, runner, _) = fixture(false, false, false);
        assert!(run(&backend, KokoroAction::Update).unwrap().accepted);
        assert_eq!(
            runner.containers.lock().unwrap().get(CONTAINER),
            Some(&(false, IMAGE.into()))
        );
        assert!(
            runner
                .calls
                .lock()
                .unwrap()
                .iter()
                .any(|a| a == &["update", "--restart", "no", CONTAINER])
        );
        assert!(run(&backend, KokoroAction::Enable).unwrap().accepted);
        assert!(run(&backend, KokoroAction::Disable).unwrap().accepted);
        assert_eq!(
            runner.containers.lock().unwrap().get(CONTAINER),
            Some(&(false, IMAGE.into()))
        );
    }
    #[test]
    fn enabling_legacy_dns_recreates_instead_of_restarting_the_old_container() {
        let (_dir, backend, runner, _) = fixture(false, false, false);
        runner
            .legacy_dns
            .store(true, std::sync::atomic::Ordering::Relaxed);
        assert!(run(&backend, KokoroAction::Enable).unwrap().accepted);
        assert!(
            runner
                .calls
                .lock()
                .unwrap()
                .iter()
                .any(|a| a.first().is_some_and(|v| v == "run")
                    && a.iter().any(|v| v == "--dns=127.0.0.1"))
        );
        assert_eq!(
            runner.containers.lock().unwrap().get(CONTAINER),
            Some(&(true, IMAGE.into()))
        );
    }

    #[test]
    fn failed_dns_migration_does_not_restart_the_unsafe_previous_container() {
        let (_dir, backend, runner, old) = fixture(false, true, false);
        runner
            .legacy_dns
            .store(true, std::sync::atomic::Ordering::Relaxed);
        assert!(!run(&backend, KokoroAction::Enable).unwrap().accepted);
        assert_eq!(
            runner.containers.lock().unwrap().get(CONTAINER),
            Some(&(false, old))
        );
    }

    #[test]
    fn kokoro_refuses_foreign_container_before_mutating_it() {
        let (_dir, backend, runner, _) = fixture(true, false, true);
        assert!(run(&backend, KokoroAction::Install).is_err());
        assert_eq!(runner.calls.lock().unwrap().len(), 1);
    }
}
