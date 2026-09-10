use super::*;
use crate::protocol::SearxngAction;
use crate::searxng::{CONTAINER, IMAGE, PORT, SETTINGS_DIRECTORY, SETTINGS_PATH};

static MUTATION: std::sync::Mutex<()> = std::sync::Mutex::new(());

impl DockerBackend {
    fn searxng_command(&self, args: Vec<String>) -> Result<(), BackendError> {
        let output = self.run_appliance(&self.docker_bin, args, None)?;
        if output.success() {
            Ok(())
        } else {
            Err(BackendError::Failure(
                "Search container command failed".into(),
            ))
        }
    }

    fn inspect_searxng(&self) -> Result<Option<(bool, String)>, BackendError> {
        let output = self.run_appliance(
            &self.docker_bin,
            vec!["inspect".into(), CONTAINER.into()],
            None,
        )?;
        if !output.success() {
            if docker_reports_missing_container(&output.stderr) {
                return Ok(None);
            }
            return Err(BackendError::Failure("Search status is unavailable".into()));
        }
        let values: Vec<serde_json::Value> = serde_json::from_slice(&output.stdout)
            .map_err(|_| BackendError::Failure("Search container inspection is invalid".into()))?;
        let value = values
            .first()
            .ok_or_else(|| BackendError::Failure("Search inspection is empty".into()))?;
        let image = value["Config"]["Image"].as_str().unwrap_or("");
        if value["Config"]["Labels"]["spark.service"] != "searxng"
            || !image.starts_with("docker.io/searxng/searxng@sha256:")
            || !valid_pinned_image(image)
        {
            return Err(BackendError::Failure(
                "An unmanaged container occupies the search service name".into(),
            ));
        }
        Ok(Some((
            value["State"]["Running"].as_bool().unwrap_or(false),
            image.into(),
        )))
    }

    fn searxng_healthy(&self) -> bool {
        let address = SocketAddr::from(([127, 0, 0, 1], PORT));
        let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_millis(300))
        else {
            return false;
        };
        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
        if stream
            .write_all(b"GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
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

    fn wait_for_searxng(&self) -> bool {
        let deadline = Instant::now() + Duration::from_secs(90);
        while Instant::now() < deadline {
            if self.searxng_healthy() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        false
    }

    /// Write the fixed settings with a fresh secret through helper-owned no-follow descriptors; the container only reads it.
    fn write_searxng_settings(&self) -> Result<(), BackendError> {
        let mut secret = [0_u8; 16];
        std::fs::File::open("/dev/urandom")
            .and_then(|mut file| file.read_exact(&mut secret))
            .map_err(|_| BackendError::Failure("No randomness for the search secret".into()))?;
        let secret = secret
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        crate::searxng::write_settings(
            Path::new(SETTINGS_DIRECTORY),
            &crate::searxng::settings_file(&secret),
        )
        .map_err(|error| BackendError::Failure(error.to_string()))
    }

    pub(super) fn execute_searxng(
        &self,
        operation: &PrivilegedOperation,
    ) -> Result<PrivilegedResponse, BackendError> {
        let PrivilegedOperation::SearxngService { request_id, action } = operation else {
            unreachable!()
        };
        let reply = |accepted, code: &str, details| PrivilegedResponse {
            request_id: *request_id,
            accepted,
            code: code.into(),
            message: "Search service operation".into(),
            details,
        };
        if self.plan_only {
            return Ok(reply(
                true,
                "planned",
                serde_json::json!({"argv": crate::searxng::launch_args(IMAGE)}),
            ));
        }
        if *action == SearxngAction::Status {
            let current = self.inspect_searxng()?;
            return Ok(reply(
                true,
                "searxng_status",
                serde_json::json!({
                    "installed": current.is_some(),
                    "running": current.as_ref().is_some_and(|value| value.0),
                    "healthy": current.as_ref().is_some_and(|value| value.0) && self.searxng_healthy(),
                    "image": current.map(|value| value.1),
                    "port": PORT,
                }),
            ));
        }
        let _guard = MUTATION
            .lock()
            .map_err(|_| BackendError::Failure("Search operation lock is unavailable".into()))?;
        let current = self.inspect_searxng()?;
        if *action == SearxngAction::Remove {
            if current.is_some() {
                self.searxng_command(vec!["rm".into(), "-f".into(), CONTAINER.into()])?;
            }
            let _ = std::fs::remove_file(SETTINGS_PATH);
            return Ok(reply(
                true,
                "searxng_removed",
                serde_json::json!({"installed": false}),
            ));
        }
        if let Some((running, image)) = &current
            && image == IMAGE
        {
            if !running {
                self.searxng_command(vec!["start".into(), CONTAINER.into()])?;
            }
            if self.wait_for_searxng() {
                return Ok(reply(
                    true,
                    "searxng_ready",
                    serde_json::json!({"image": IMAGE, "port": PORT, "healthy": true}),
                ));
            }
        }
        self.pull_image(IMAGE)?;
        self.write_searxng_settings()?;
        if current.is_some() {
            self.searxng_command(vec!["rm".into(), "-f".into(), CONTAINER.into()])?;
        }
        self.searxng_command(crate::searxng::launch_args(IMAGE))?;
        let healthy = self.wait_for_searxng();
        Ok(reply(
            healthy,
            if healthy {
                "searxng_ready"
            } else {
                "SEARXNG_START_FAILED"
            },
            serde_json::json!({"image": IMAGE, "port": PORT, "healthy": healthy}),
        ))
    }
}
