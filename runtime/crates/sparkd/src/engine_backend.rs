//! Launch production engines through typed privileged operations and probe them over loopback; provide a loopback-only development stub.

use std::convert::Infallible;

use std::fmt;

use std::net::{SocketAddr, TcpListener as StdTcpListener};

use std::pin::Pin;

use std::sync::Arc;

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use std::task::{Context, Poll};

use std::time::Duration;

use async_trait::async_trait;

use axum::Json;

use axum::body::Body;

use axum::extract::{DefaultBodyLimit, State};

use axum::http::StatusCode;

use axum::response::sse::Event;

use axum::response::{IntoResponse, Response, Sse};

use axum::routing::{get, post};

use futures::{Stream, StreamExt};

use serde_json::{Value, json};

use spark_privd::protocol::PrivilegedOperation;

use spark_privd::protocol::SecretString;

use tokio::sync::{mpsc, oneshot};

use tokio_stream::wrappers::ReceiverStream;

use uuid::Uuid;

use crate::engine::{
    BackendError, ContainerRuntimeReport, EngineBackend, EngineImagePreparation, EngineInstance,
    TYPED_LAUNCH_FAILURE_CODES,
};

use crate::privd::PrivilegedClient;

/// Bound live runtime probes so a stalled helper cannot hang capabilities requests.
const CONTAINER_RUNTIME_PROBE_TIMEOUT: Duration = Duration::from_secs(2);

pub struct DockerEngineBackend {
    privd: PrivilegedClient,
    http: reqwest::Client,
}

impl DockerEngineBackend {
    pub fn new(privd: PrivilegedClient) -> Self {
        Self {
            privd,
            http: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(2))
                .timeout(Duration::from_secs(5))
                .build()
                .expect("loopback http client"),
        }
    }

    async fn call_privileged(
        &self,
        operation: PrivilegedOperation,
    ) -> Result<spark_privd::protocol::PrivilegedResponse, BackendError> {
        let client = self.privd.clone();
        tokio::task::spawn_blocking(move || client.call(operation))
            .await
            .map_err(|error| BackendError(format!("privileged task: {error}")))?
            .map_err(|error| BackendError(format!("privileged operation: {error}")))
    }

    /// Return container running evidence, or None when inspection is unavailable and callers must consult the port.
    async fn container_running(&self, instance: &EngineInstance) -> Option<bool> {
        let expected_name = instance
            .external_workload_id
            .clone()
            .unwrap_or_else(|| format!("spark-model-{}", instance.instance_id));
        let privileged = self.privd.clone();
        let response = tokio::task::spawn_blocking(move || {
            privileged.call(
                spark_privd::protocol::PrivilegedOperation::InventoryWorkloads {
                    request_id: uuid::Uuid::new_v4(),
                },
            )
        })
        .await
        .ok()?
        .ok()?;
        if !response.accepted {
            return None;
        }
        let observed: spark_privd::workloads::ObservedWorkloads =
            serde_json::from_value(response.details).ok()?;
        // A truncated inventory cannot prove absence.
        if observed.truncated {
            return None;
        }
        Some(observed.containers.iter().any(|container| {
            let matches = container.id == expected_name
                || container.name.as_deref() == Some(expected_name.as_str());
            matches && container.state == "running"
        }))
    }
}

#[async_trait]
impl EngineBackend for DockerEngineBackend {
    async fn prepare(
        &self,
        instance: &EngineInstance,
    ) -> Result<EngineImagePreparation, BackendError> {
        let requested_digest = &instance.recipe.engine.image;
        let request_id = Uuid::new_v4();
        let image = self
            .call_privileged(PrivilegedOperation::EnsureEngineImage {
                request_id,
                image_digest: requested_digest.clone(),
            })
            .await
            .map_err(|e| BackendError(format!("privileged image preparation: {e}")))?;
        // Match response request IDs as well as digests so stale replies cannot satisfy new image requests.
        if image.request_id != request_id {
            return Err(BackendError(
                "privileged image preparation answered a different request".into(),
            ));
        }
        if !image.accepted {
            return Err(BackendError(format!(
                "privileged image preparation rejected: {}",
                image.message
            )));
        }
        if image.code != "image_ready"
            || image.details.get("image_digest").and_then(Value::as_str)
                != Some(requested_digest.as_str())
        {
            return Err(BackendError(
                "privileged image preparation returned an invalid readiness claim".into(),
            ));
        }
        match image.details.get("pulled").and_then(Value::as_bool) {
            Some(true) => Ok(EngineImagePreparation::Pulled),
            Some(false) => Ok(EngineImagePreparation::AlreadyAvailable),
            None => Err(BackendError(
                "privileged image preparation omitted its pull result".into(),
            )),
        }
    }

    async fn launch(&self, instance: &EngineInstance) -> Result<u16, BackendError> {
        self.launch_accounted(instance).await.map(|(port, _)| port)
    }

    async fn launch_accounted(
        &self,
        instance: &EngineInstance,
    ) -> Result<(u16, u64), BackendError> {
        let response = self
            .call_privileged(PrivilegedOperation::StartModel {
                request_id: Uuid::new_v4(),
                recipe_id: instance.model_id.clone(),
                profile_id: instance.profile_id.clone(),
                instance_id: instance.instance_id,
                image_digest: instance.recipe.engine.image.clone(),
                served_name: instance.served_name.clone(),
                model_snapshot: instance.model_snapshot.to_string_lossy().into_owned(),
                host_port: instance.internal_port,
                api_key: SecretString::new(instance.api_key.clone()),
                gpu_memory_utilisation_milli: instance.gpu_memory_utilisation_milli,
                max_model_length: instance.profile.max_model_length,
                max_sequences: instance.profile.max_sequences,
                max_batched_tokens: instance.profile.max_batched_tokens,
                allow_network_during_inference: instance
                    .recipe
                    .security
                    .allow_network_during_inference,
                memory_limit_bytes: instance.memory_limit_bytes,
                // ADR-043: KV plus recurrent state is the cache vLLM sizes; without arithmetic the utilisation share decides.
                kv_cache_memory_bytes: instance
                    .recipe
                    .reservation(&instance.profile)
                    .map(|reservation| reservation.engine_cache_bytes()),
                engine_options: spark_privd::protocol::EngineLaunchOptions {
                    preparation: instance
                        .recipe
                        .engine
                        .options
                        .as_ref()
                        .and_then(|options| options.preparation)
                        .map(|_| "qwen38_78b0675".to_owned()),
                    mamba_cache_mode: instance
                        .recipe
                        .engine
                        .options
                        .as_ref()
                        .and_then(|options| options.mamba_cache_mode)
                        .map(|mode| mode.as_flag_value().to_owned()),
                    kv_cache_dtype: instance
                        .recipe
                        .engine
                        .options
                        .as_ref()
                        .and_then(|options| options.kv_cache_dtype)
                        .map(|dtype| dtype.as_flag_value().to_owned()),
                    tool_call_parser: instance
                        .recipe
                        .engine
                        .options
                        .as_ref()
                        .and_then(|options| options.tool_call_parser)
                        .map(|parser| parser.as_flag_value().to_owned()),
                    reasoning_parser: instance
                        .recipe
                        .engine
                        .options
                        .as_ref()
                        .and_then(|options| options.reasoning_parser)
                        .map(|parser| parser.as_flag_value().to_owned()),
                },
            })
            .await
            .map_err(|e| BackendError(format!("privileged launch: {e}")))?;
        if !response.accepted {
            // A typed rejection leads with its stable code; the prose and the helper's evidence follow as detail.
            if TYPED_LAUNCH_FAILURE_CODES.contains(&response.code.as_str()) {
                return Err(BackendError(format!(
                    "{}: {} [{}]",
                    response.code, response.message, response.details
                )));
            }
            return Err(BackendError(format!(
                "privileged launch rejected: {}",
                response.message
            )));
        }
        let reserved = if instance.recipe.uses_qwen38_preparation() {
            response.details["host_reserved_memory_bytes"]
                .as_u64()
                .unwrap_or(0)
        } else {
            0
        };
        Ok((instance.internal_port, reserved))
    }

    async fn stop(&self, instance: &EngineInstance, force: bool) -> Result<(), BackendError> {
        let operation = match &instance.external_workload_id {
            Some(workload_id) => PrivilegedOperation::StopAdoptedModel {
                request_id: Uuid::new_v4(),
                workload_id: workload_id.clone(),
                force,
            },
            None => PrivilegedOperation::StopModel {
                request_id: Uuid::new_v4(),
                instance_id: instance.instance_id,
                force,
            },
        };
        let response = self
            .privd
            .call(operation)
            .map_err(|e| BackendError(format!("privileged stop: {e}")))?;
        if !response.accepted {
            return Err(BackendError(format!(
                "privileged stop rejected: {}",
                response.message
            )));
        }
        Ok(())
    }

    async fn reconcile_instance(
        &self,
        instance_id: Uuid,
        external_workload_id: Option<&str>,
    ) -> Result<(), BackendError> {
        let operation = match external_workload_id {
            Some(workload_id) => PrivilegedOperation::StopAdoptedModel {
                request_id: Uuid::new_v4(),
                workload_id: workload_id.to_owned(),
                force: true,
            },
            None => PrivilegedOperation::StopModel {
                request_id: Uuid::new_v4(),
                instance_id,
                force: true,
            },
        };
        let response = self
            .privd
            .call(operation)
            .map_err(|error| BackendError(format!("privileged reconciliation stop: {error}")))?;
        if !response.accepted {
            return Err(BackendError(format!(
                "privileged reconciliation rejected: {}",
                response.message
            )));
        }
        Ok(())
    }

    /// Prefer exact container state over port occupancy, using the port only when container inspection is unavailable.
    async fn is_running(&self, instance: &EngineInstance) -> bool {
        if let Some(running) = self.container_running(instance).await {
            return running;
        }
        let addr =
            std::net::SocketAddr::from((std::net::Ipv4Addr::LOCALHOST, instance.internal_port));
        std::net::TcpStream::connect_timeout(&addr, Duration::from_millis(500)).is_ok()
    }

    async fn has_exited(&self, instance: &EngineInstance) -> bool {
        self.container_running(instance).await == Some(false)
    }

    async fn health(&self, instance: &EngineInstance) -> Result<bool, BackendError> {
        let url = format!("http://127.0.0.1:{}/health", instance.internal_port);
        match self.http.get(&url).send().await {
            Ok(resp) => Ok(resp.status().is_success()),
            Err(e) => Err(BackendError(format!("health probe: {e}"))),
        }
    }

    async fn list_model_names(
        &self,
        instance: &EngineInstance,
    ) -> Result<Vec<String>, BackendError> {
        let url = format!("http://127.0.0.1:{}/v1/models", instance.internal_port);
        let mut request = self.http.get(&url);
        if !instance.api_key.is_empty() {
            request = request.bearer_auth(&instance.api_key);
        }
        let resp = request
            .send()
            .await
            .map_err(|e| BackendError(format!("models probe: {e}")))?;
        let body: Value = resp
            .json()
            .await
            .map_err(|e| BackendError(format!("models parse: {e}")))?;
        Ok(body
            .get("data")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
            .iter()
            .filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_owned))
            .collect())
    }

    async fn probe_completion(&self, instance: &EngineInstance) -> Result<(), BackendError> {
        let url = format!(
            "http://127.0.0.1:{}/v1/chat/completions",
            instance.internal_port
        );
        let body = json!({
            "model": instance.served_name,
            "messages": [{"role": "user", "content": "ping"}],
            "max_tokens": 2,
            "stream": false,
        });
        let mut request = self.http.post(&url);
        if !instance.api_key.is_empty() {
            request = request.bearer_auth(&instance.api_key);
        }
        let resp = request
            .json(&body)
            .send()
            .await
            .map_err(|e| BackendError(format!("completion probe: {e}")))?;
        if resp.status() != StatusCode::OK {
            return Err(BackendError(format!(
                "completion probe status {}",
                resp.status()
            )));
        }
        Ok(())
    }

    fn probe_container_runtime(&self) -> ContainerRuntimeReport {
        let report = self.privd.call_bounded(
            PrivilegedOperation::ProbeContainerRuntime {
                request_id: Uuid::new_v4(),
            },
            CONTAINER_RUNTIME_PROBE_TIMEOUT,
        );
        match report {
            Ok(response) => {
                let available = response.accepted && response.code == "runtime_available";
                let detail = if available {
                    None
                } else {
                    Some(response.message)
                };
                // Treat only explicit runtime-probe booleans as evidence; other values remain unknown.
                let gpu_runtime = response
                    .details
                    .get("gpu_runtime")
                    .and_then(serde_json::Value::as_bool);
                ContainerRuntimeReport::new("docker", available, detail)
                    .with_gpu_runtime(gpu_runtime)
            }
            Err(error) => ContainerRuntimeReport::new(
                "docker",
                false,
                Some(format!("container runtime probe failed: {error}")),
            ),
        }
    }
}

mod mock_backend;
use mock_backend::MockShared;
pub use mock_backend::MockVllmBackend;

mod mock_http;
use mock_http::mock_router;
