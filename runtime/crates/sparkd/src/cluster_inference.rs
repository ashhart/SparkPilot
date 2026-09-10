//! Capability-gated routing for Spark-managed distributed inference.

use std::task::{Context, Poll};
use std::time::{Duration, SystemTime};

use axum::Json;
use axum::http::StatusCode;
use rusqlite::OptionalExtension;
use serde_json::{Value, json};
use tokio_stream::wrappers::WatchStream;
use tokio_stream::{Stream, StreamExt};

use crate::engine::RequestTicket;
use crate::state::AppState;

fn err(code: &str, message: impl Into<String>, status: StatusCode) -> (StatusCode, Json<Value>) {
    (
        status,
        Json(json!({ "error": { "code": code, "message": message.into() } })),
    )
}

fn cluster_inference_unavailable() -> (StatusCode, Json<Value>) {
    err(
        "CLUSTER_INFERENCE_UNAVAILABLE",
        "Distributed inference is unavailable because this runtime has no qualified cluster launch backend.",
        StatusCode::CONFLICT,
    )
}

pub(crate) fn peer_loss_message(
    loss: crate::cluster_coordination::ClusterPeerLoss,
) -> &'static str {
    match loss {
        crate::cluster_coordination::ClusterPeerLoss::Worker => {
            "The cluster worker was lost, so this request was stopped."
        }
        crate::cluster_coordination::ClusterPeerLoss::Coordinator => {
            "The cluster coordinator was lost, so this request was stopped."
        }
    }
}

pub(crate) fn peer_loss_envelope(
    loss: crate::cluster_coordination::ClusterPeerLoss,
) -> (StatusCode, Json<Value>) {
    err(
        loss.request_failure_code(),
        peer_loss_message(loss),
        StatusCode::SERVICE_UNAVAILABLE,
    )
}

#[derive(Clone)]
pub(crate) struct ClusterInferenceRoute {
    pub(crate) launch_id: uuid::Uuid,
    pub(crate) cluster_id: uuid::Uuid,
    pub(crate) profile_id: String,
    pub(crate) max_model_length: u64,
    pub(crate) upstream: crate::engine::EngineUpstream,
    failure_receiver:
        tokio::sync::watch::Receiver<Option<crate::cluster_coordination::ClusterPeerLoss>>,
}

/// Resolve qualified coordinator-owned engines from trusted state without caller-selected addresses, ports, images or paths.
pub(crate) fn cluster_inference_route(
    state: &AppState,
    requested_cluster: Option<&str>,
    requested_model: Option<&str>,
    infer_from_model: bool,
    qualified: bool,
) -> Result<Option<ClusterInferenceRoute>, (StatusCode, Json<Value>)> {
    let requested_cluster = requested_cluster
        .map(|value| {
            uuid::Uuid::parse_str(value).map_err(|_| {
                err(
                    "TARGET_IDENTITY_MISMATCH",
                    "The requested node or cluster is not this runtime target.",
                    StatusCode::CONFLICT,
                )
            })
        })
        .transpose()?;
    if requested_cluster.is_some() && !qualified {
        return Err(cluster_inference_unavailable());
    }
    if requested_cluster.is_none() && !infer_from_model {
        return Ok(None);
    }

    let Some(coordinator) = state.cluster_coordination.as_ref() else {
        return if requested_cluster.is_some() {
            Err(cluster_inference_unavailable())
        } else {
            Ok(None)
        };
    };
    let statuses = coordinator
        .launches()
        .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
    let mut routes = Vec::new();
    for status in statuses.into_iter().filter(|status| {
        status.state == "running"
            && status.coordinator_node_id == state.identity.node_id()
            && requested_cluster.is_none_or(|cluster_id| status.cluster_id == cluster_id)
    }) {
        let Some(database) = state.database.as_ref() else {
            return Err(crate::models::internal_envelope("no database"));
        };
        let row: Option<(String, String, String, String, String)> = database
            .lock()
            .query_row(
                "SELECT l.execution_spec_json,t.proposal_json,t.proposal_digest,
                        t.owner_device_id,t.transaction_id
                   FROM cluster_launches l
                   JOIN cluster_transactions t ON t.cluster_id=l.cluster_id
                  WHERE l.launch_id=?1 AND l.cluster_id=?2 AND l.state='running'
                    AND t.state='ready' AND t.coordinator_node_id=l.coordinator_node_id",
                rusqlite::params![status.launch_id.to_string(), status.cluster_id.to_string()],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
        let Some((execution_json, proposal_json, proposal_digest, owner_device_id, transaction_id)) =
            row
        else {
            continue;
        };
        let execution: crate::cluster_coordination::DistributedExecutionSpec =
            serde_json::from_str(&execution_json)
                .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
        execution
            .validate(status.launch_id)
            .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
        let proposal: crate::cluster_coordination::ClusterProposal =
            serde_json::from_str(&proposal_json)
                .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
        let calculated_proposal_digest = proposal
            .digest()
            .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
        let worker_is_member = proposal.members.iter().any(|member| {
            member.node_id == status.worker_node_id && member.node_id != status.coordinator_node_id
        });
        if proposal.cluster_id != status.cluster_id
            || proposal.transaction_id.to_string() != transaction_id
            || proposal.coordinator_node_id != status.coordinator_node_id
            || proposal.owner_device_id.to_string() != owner_device_id
            || calculated_proposal_digest != proposal_digest
            || !worker_is_member
            || execution.recipe_id != status.recipe_id
            || execution.profile_id != status.profile_id
        {
            return Err(crate::models::internal_envelope(
                "cluster launch identity is inconsistent",
            ));
        }
        let managed_membership: bool = database
            .lock()
            .query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM cluster_state s
                     WHERE s.singleton=1 AND s.id=?1 AND s.state='ready'
                       AND (SELECT COUNT(*) FROM cluster_members m
                             WHERE m.cluster_id=s.id
                               AND m.node_id IN (?2,?3))=2
                       AND (SELECT COUNT(*) FROM cluster_members m
                             WHERE m.cluster_id=s.id)=2
                 )",
                rusqlite::params![
                    status.cluster_id.to_string(),
                    status.coordinator_node_id.to_string(),
                    status.worker_node_id.to_string(),
                ],
                |row| row.get(0),
            )
            .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
        if !managed_membership {
            return Err(crate::models::internal_envelope(
                "cluster launch is not tied to the active managed membership",
            ));
        }
        let owner_is_live: bool = database
            .lock()
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM devices
                  WHERE id=?1 AND revoked_at IS NULL AND role IN ('owner','administrator'))",
                [owner_device_id],
                |row| row.get(0),
            )
            .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
        if !owner_is_live {
            return Err(err(
                "ROLE_FORBIDDEN",
                "The managed cluster launch no longer has a live administrator owner.",
                StatusCode::FORBIDDEN,
            ));
        }
        routes.push(ClusterInferenceRoute {
            launch_id: status.launch_id,
            cluster_id: status.cluster_id,
            profile_id: status.profile_id,
            max_model_length: execution.max_model_length,
            upstream: crate::engine::EngineUpstream {
                host_port: execution.host_port,
                api_key: String::new(),
                model_id: execution.recipe_id,
                served_name: execution.served_name,
            },
            failure_receiver: coordinator.launch_failure_receiver(status.launch_id),
        });
    }
    if routes.len() > 1 {
        return Err(crate::models::internal_envelope(
            "multiple managed cluster engines matched one inference request",
        ));
    }
    let route = routes.pop();
    if route.is_some() && !qualified {
        return Err(cluster_inference_unavailable());
    }
    if let (Some(route), Some(model)) = (&route, requested_model)
        && model != route.upstream.model_id
        && model != route.upstream.served_name
    {
        return Err(err(
            "MODEL_NOT_LOADED",
            format!(
                "model {} is not the active cluster engine ({})",
                crate::api_error::abbreviated(model),
                route.upstream.served_name
            ),
            StatusCode::NOT_FOUND,
        ));
    }
    if route.is_none() && requested_cluster.is_some() {
        return Err(err(
            "MODEL_NOT_LOADED",
            "no running managed engine exists for the requested cluster",
            StatusCode::NOT_FOUND,
        ));
    }
    Ok(route)
}

/// Verify live vLLM health because a persisted running row may outlast the process.
pub(crate) async fn verify_cluster_route_health(
    route: &ClusterInferenceRoute,
) -> Result<(), (StatusCode, Json<Value>)> {
    let client = reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|error| crate::models::internal_envelope(&error.to_string()))?;
    let response = client
        .get(format!(
            "http://127.0.0.1:{}/health",
            route.upstream.host_port
        ))
        .send()
        .await
        .map_err(|_| {
            err(
                "ENGINE_NOT_READY",
                "The managed cluster engine did not pass its local health check.",
                StatusCode::CONFLICT,
            )
        })?;
    if !response.status().is_success() {
        return Err(err(
            "ENGINE_NOT_READY",
            "The managed cluster engine did not pass its local health check.",
            StatusCode::CONFLICT,
        ));
    }
    Ok(())
}

pub(crate) enum InferenceRequestTicket {
    Local(RequestTicket),
    Cluster {
        started: SystemTime,
        ttft_ms: Option<f64>,
        failures: WatchStream<Option<crate::cluster_coordination::ClusterPeerLoss>>,
    },
}

impl InferenceRequestTicket {
    pub(crate) fn cluster(route: &ClusterInferenceRoute) -> Self {
        Self::cluster_with_receiver(route.failure_receiver.clone())
    }

    #[cfg(test)]
    pub(crate) fn cluster_with_sender(
        sender: &tokio::sync::watch::Sender<Option<crate::cluster_coordination::ClusterPeerLoss>>,
    ) -> Self {
        Self::cluster_with_receiver(sender.subscribe())
    }

    fn cluster_with_receiver(
        receiver: tokio::sync::watch::Receiver<
            Option<crate::cluster_coordination::ClusterPeerLoss>,
        >,
    ) -> Self {
        Self::Cluster {
            started: SystemTime::now(),
            ttft_ms: None,
            failures: WatchStream::new(receiver),
        }
    }

    pub(crate) async fn wait_cluster_failure(
        &mut self,
    ) -> crate::cluster_coordination::ClusterPeerLoss {
        match self {
            Self::Cluster { failures, .. } => loop {
                match failures.next().await {
                    Some(Some(loss)) => return loss,
                    Some(None) => continue,
                    None => std::future::pending().await,
                }
            },
            Self::Local(_) => std::future::pending().await,
        }
    }

    pub(crate) fn poll_cluster_failure(
        &mut self,
        context: &mut Context<'_>,
    ) -> Poll<Option<crate::cluster_coordination::ClusterPeerLoss>> {
        match self {
            Self::Cluster { failures, .. } => loop {
                match std::pin::Pin::new(&mut *failures).poll_next(context) {
                    Poll::Ready(Some(Some(loss))) => return Poll::Ready(Some(loss)),
                    Poll::Ready(Some(None)) => continue,
                    Poll::Ready(None) | Poll::Pending => return Poll::Pending,
                }
            },
            Self::Local(_) => Poll::Pending,
        }
    }

    pub(crate) fn elapsed(&self) -> Option<Duration> {
        match self {
            Self::Local(ticket) => ticket.elapsed(),
            Self::Cluster { started, .. } => started.elapsed().ok(),
        }
    }

    pub(crate) fn ttft_ms(&self) -> Option<f64> {
        match self {
            Self::Local(ticket) => ticket.ttft_ms(),
            Self::Cluster { ttft_ms, .. } => *ttft_ms,
        }
    }

    pub(crate) fn note_first_frame(&mut self) {
        match self {
            Self::Local(ticket) => ticket.note_first_frame(),
            Self::Cluster {
                started, ttft_ms, ..
            } if ttft_ms.is_none() => {
                *ttft_ms = started
                    .elapsed()
                    .ok()
                    .map(|elapsed| elapsed.as_secs_f64() * 1_000.0);
            }
            Self::Cluster { .. } => {}
        }
    }

    pub(crate) fn note_complete(&mut self, tokens_per_second: Option<f64>) {
        if let Self::Local(ticket) = self {
            ticket.note_complete(tokens_per_second);
        }
    }
}

#[cfg(test)]
#[path = "cluster_inference/cluster_routing_tests.rs"]
mod cluster_routing_tests;
