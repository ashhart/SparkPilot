//! The real transport and the real model: bounded GETs to the public internet, and one loopback completion.

use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;

use super::session::{TransportRequest, TransportResponse, WebTransport};
use super::tool_loop::ModelChat;
use crate::state::AppState;

#[cfg(test)]
mod tests;

/// The only user agent the Spark presents, so a site owner can recognise and refuse it.
pub use super::robots::USER_AGENT;
/// How long one completion in a tool loop may take.
const MODEL_TIMEOUT_SECONDS: u64 = 180;
/// Bound the model's own answer so one run cannot fill the daemon.
const MAX_MODEL_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

/// GET only, no cookies, no redirects followed by the client, nothing about this house.
pub struct HttpTransport {
    client: reqwest::Client,
}

/// One shared shape for every outbound client, pinned or not.
fn builder() -> reqwest::ClientBuilder {
    // reqwest is built without its cookie feature, so no jar exists to send from.
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(USER_AGENT)
        .timeout(Duration::from_secs(30))
}

impl HttpTransport {
    pub fn new() -> Result<Self, String> {
        let client = builder().build().map_err(|error| error.to_string())?;
        Ok(Self { client })
    }

    /// Connect only to the addresses the guard checked, so the name cannot answer differently now.
    fn pinned(request: &TransportRequest) -> Result<reqwest::Client, String> {
        let url = reqwest::Url::parse(&request.url).map_err(|error| error.to_string())?;
        let host = url.host_str().ok_or("no host")?;
        let port = url.port_or_known_default().unwrap_or(443);
        let sockets: Vec<std::net::SocketAddr> = request
            .addresses
            .iter()
            .map(|address| std::net::SocketAddr::new(*address, port))
            .collect();
        builder()
            .resolve_to_addrs(host, &sockets)
            .build()
            .map_err(|error| error.to_string())
    }
}

#[async_trait::async_trait]
impl WebTransport for HttpTransport {
    async fn get(&self, request: &TransportRequest) -> Result<TransportResponse, String> {
        let pinned;
        let client = if request.addresses.is_empty() {
            let url = reqwest::Url::parse(&request.url).map_err(|_| "invalid destination")?;
            if !super::backend::is_packaged_searxng(url.as_str()) {
                return Err("unpinned public destination".to_owned());
            }
            &self.client
        } else {
            pinned = Self::pinned(request)?;
            &pinned
        };
        let mut builder = client
            .get(&request.url)
            .header(reqwest::header::ACCEPT, request.accept)
            .timeout(Duration::from_secs(request.timeout_seconds));
        if let Some((name, value)) = &request.secret_header {
            builder = builder.header(*name, value.clone());
        }
        let response = builder.send().await.map_err(|error| error.to_string())?;
        let status = response.status().as_u16();
        let location = response
            .headers()
            .get(reqwest::header::LOCATION)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default()
            .to_ascii_lowercase();
        let body = read_bounded(response, request.max_bytes).await?;
        let bytes = body.len();
        Ok(TransportResponse {
            status,
            location,
            content_type,
            body: String::from_utf8_lossy(&body).into_owned(),
            bytes,
        })
    }
}

/// Stop reading at the ceiling rather than buffering whatever a site chooses to send.
async fn read_bounded(response: reqwest::Response, limit: usize) -> Result<Vec<u8>, String> {
    use futures::StreamExt as _;
    let mut collected: Vec<u8> = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| error.to_string())?;
        if collected.len().saturating_add(chunk.len()) > limit {
            collected.extend_from_slice(&chunk[..limit.saturating_sub(collected.len())]);
            break;
        }
        collected.extend_from_slice(&chunk);
    }
    Ok(collected)
}

/// One completion against this Spark's own engine on loopback; the container never reaches the internet.
pub struct LoopbackModel {
    state: AppState,
}

impl LoopbackModel {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }
}

#[async_trait::async_trait]
impl ModelChat for LoopbackModel {
    async fn complete(
        &self,
        model: &str,
        messages: &[Value],
        _tools: &Value,
    ) -> Result<Value, String> {
        let manager = self
            .state
            .engine
            .manager
            .as_ref()
            .ok_or_else(|| "no engine".to_owned())?;
        let (_ticket, upstream) = manager
            .admit_request(model)
            .map_err(|error| error.code().to_owned())?;
        let body = serde_json::json!({
            "model": upstream.served_name,
            "messages": messages,
            "stream": false,
        });
        let client = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|error| error.to_string())?;
        let url = format!(
            "http://127.0.0.1:{}/v1/chat/completions",
            upstream.host_port
        );
        let mut request = client.post(&url);
        if !upstream.api_key.is_empty() {
            request = request.bearer_auth(&upstream.api_key);
        }
        let response = request
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .timeout(Duration::from_secs(MODEL_TIMEOUT_SECONDS))
            .body(serde_json::to_vec(&body).map_err(|error| error.to_string())?)
            .send()
            .await
            .map_err(|error| error.to_string())?;
        if !response.status().is_success() {
            return Err(format!("engine answered {}", response.status()));
        }
        let bytes = read_bounded(response, MAX_MODEL_RESPONSE_BYTES).await?;
        let value: Value = serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
        value
            .pointer("/choices/0/message")
            .cloned()
            .ok_or_else(|| "the engine returned no message".to_owned())
    }
}

/// The transport, resolver and clock one live run shares.
pub fn live_transport() -> Option<Arc<dyn WebTransport>> {
    match HttpTransport::new() {
        Ok(transport) => Some(Arc::new(transport)),
        Err(error) => {
            tracing::error!(%error, "the web transport could not be built");
            None
        }
    }
}
