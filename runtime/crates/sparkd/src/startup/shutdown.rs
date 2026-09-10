// Stop when the service manager asks: refuse new connections, let in-flight requests finish, and say so.

use std::future::Future;
use std::net::SocketAddr;
use std::time::Duration;

use axum_server::Handle;

/// How long an in-flight request has to finish before the listener is closed anyway.
pub(super) const DRAIN_GRACE: Duration = Duration::from_secs(20);

/// Watch for SIGTERM and SIGINT for the life of the process.
pub(super) fn spawn(handle: Handle<SocketAddr>, drain: Duration) {
    tokio::spawn(async move {
        drain_on(handle, first_signal(), drain).await;
    });
}

/// Announce the stop before draining, so a service manager never counts a draining daemon as ready.
pub(super) async fn drain_on(
    handle: Handle<SocketAddr>,
    signal: impl Future<Output = &'static str>,
    drain: Duration,
) {
    let name = signal.await;
    tracing::info!(
        signal = name,
        seconds = drain.as_secs(),
        "stopping: no new connections, finishing the requests already in flight"
    );
    let _ = spark_core::notify::stopping();
    handle.graceful_shutdown(Some(drain));
}

/// Whichever of the two stop signals arrives first.
async fn first_signal() -> &'static str {
    use tokio::signal::unix::{SignalKind, signal};
    let (Ok(mut terminate), Ok(mut interrupt)) = (
        signal(SignalKind::terminate()),
        signal(SignalKind::interrupt()),
    ) else {
        tracing::error!("stop signals could not be installed; this daemon will not drain on stop");
        return std::future::pending().await;
    };
    tokio::select! {
        _ = terminate.recv() => "SIGTERM",
        _ = interrupt.recv() => "SIGINT",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A request already in flight when the stop arrives is finished, and then the listener closes.
    #[tokio::test]
    async fn a_stop_signal_drains_the_requests_already_in_flight() {
        let app = axum::Router::new().route(
            "/slow",
            axum::routing::get(|| async {
                tokio::time::sleep(Duration::from_millis(300)).await;
                "done"
            }),
        );
        let handle: Handle<SocketAddr> = Handle::new();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address");
        listener.set_nonblocking(true).expect("nonblocking");
        let server = tokio::spawn(
            axum_server::from_tcp(listener)
                .expect("from_tcp")
                .handle(handle.clone())
                .serve(app.into_make_service()),
        );

        let request = tokio::spawn(async move {
            reqwest::Client::new()
                .get(format!("http://{address}/slow"))
                .send()
                .await
                .and_then(|response| response.error_for_status())
                .is_ok()
        });
        tokio::time::sleep(Duration::from_millis(50)).await;

        drain_on(handle, async { "SIGTERM" }, Duration::from_secs(5)).await;

        assert!(
            request.await.expect("request task"),
            "an in-flight request was cut off by the stop"
        );
        let stopped = tokio::time::timeout(Duration::from_secs(5), server).await;
        assert!(
            matches!(stopped, Ok(Ok(Ok(())))),
            "the listener did not close after the stop: {stopped:?}"
        );
        assert!(
            reqwest::Client::new()
                .get(format!("http://{address}/slow"))
                .timeout(Duration::from_secs(2))
                .send()
                .await
                .is_err(),
            "the daemon still accepted a connection after stopping"
        );
    }
}
