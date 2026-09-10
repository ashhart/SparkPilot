use super::*;
use axum::routing::post;
use std::convert::Infallible;
async fn server(
    status: StatusCode,
    chunks: Vec<Vec<u8>>,
) -> (crate::engine::EngineUpstream, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let app = axum::Router::new().route(
        "/v1/chat/completions",
        post(move || {
            let chunks = chunks.clone();
            async move {
                (
                    status,
                    Body::from_stream(futures::stream::iter(
                        chunks
                            .into_iter()
                            .map(|b| Ok::<_, Infallible>(Bytes::from(b))),
                    )),
                )
            }
        }),
    );
    let task = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (
        crate::engine::EngineUpstream {
            host_port: port,
            api_key: String::new(),
            model_id: "test".into(),
            served_name: "test".into(),
        },
        task,
    )
}
async fn collect(
    upstream: crate::engine::EngineUpstream,
    streaming: bool,
) -> (
    Option<(StatusCode, bool)>,
    Vec<u8>,
    Result<(bool, bool), ()>,
) {
    let (tx, mut rx) = tokio::sync::mpsc::channel(4);
    let (head_tx, head_rx) = tokio::sync::oneshot::channel();
    let worker = tokio::spawn(run_terminal(
        upstream,
        b"{}".to_vec(),
        streaming,
        tx,
        head_tx,
    ));
    let status = head_rx.await.ok();
    let mut bytes = Vec::new();
    while let Some(part) = rx.recv().await {
        bytes.extend_from_slice(&part.unwrap());
    }
    (status, bytes, worker.await.unwrap())
}
#[test]
fn terminal_parser_accepts_fragmented_lf_and_crlf_but_not_partial_or_multiple_data() {
    for bytes in [b"data: [DONE]\n\n".as_slice(), b"data: [DONE]\r\n\r\n"] {
        let mut parser = TerminalEvents::default();
        for b in &bytes[..bytes.len() - 1] {
            parser.push(&[*b]).unwrap();
            assert!(!parser.completed);
        }
        parser.push(&bytes[bytes.len() - 1..]).unwrap();
        assert!(parser.completed);
    }
    for bytes in [
        b"data: [D O N E]\n\n".as_slice(),
        b"data: one\ndata: [DONE]\n\n",
        b"data: [DONE]\n",
    ] {
        let mut parser = TerminalEvents::default();
        parser.push(bytes).unwrap();
        assert!(!parser.completed);
    }
}
#[tokio::test]
async fn upstream_fragmented_done_is_a_confirmed_terminal_response() {
    let (upstream, server) = server(
        StatusCode::OK,
        vec![
            b"data: {}\r\n\r\ndata: [D".to_vec(),
            b"ON".to_vec(),
            b"E]\r\n".to_vec(),
            b"\r\n".to_vec(),
        ],
    )
    .await;
    let (status, body, result) = collect(upstream, true).await;
    assert_eq!(status, Some((StatusCode::OK, true)));
    assert!(body.ends_with(b"\r\n\r\n"));
    assert_eq!(result, Ok((true, true)));
    server.abort();
}
#[tokio::test]
async fn terminal_sse_error_is_failed_even_with_a_done_marker() {
    let (upstream, server) = server(
        StatusCode::OK,
        vec![b"data: {\"error\":{\"message\":\"capacity\"}}\n\ndata: [DONE]\n\n".to_vec()],
    )
    .await;
    let (_, _, result) = collect(upstream, true).await;
    assert_eq!(result, Ok((true, false)));
    server.abort();
}
#[tokio::test]
async fn upstream_error_statuses_are_preserved_for_both_response_modes() {
    for status in [StatusCode::BAD_REQUEST, StatusCode::SERVICE_UNAVAILABLE] {
        for streaming in [false, true] {
            let (upstream, server) =
                server(status, vec![b"{\"error\":\"unavailable\"}".to_vec()]).await;
            let (head, body, result) = collect(upstream, streaming).await;
            assert_eq!(head, Some((status, false)));
            assert!(!body.is_empty());
            assert_eq!(result, Ok((true, false)));
            server.abort();
        }
    }
}
#[tokio::test]
async fn incomplete_json_and_streams_are_never_complete_success() {
    for (streaming, bytes) in [
        (false, b"{\"choices\":[]}".as_slice()),
        (false, b"{"),
        (true, b"data: {}\n\n"),
    ] {
        let (upstream, server) = server(StatusCode::OK, vec![bytes.to_vec()]).await;
        let (head, body, result) = collect(upstream, streaming).await;
        assert!(result.is_err());
        if !streaming {
            assert!(head.is_none());
            assert!(body.is_empty());
        }
        server.abort();
    }
}
#[tokio::test]
async fn connection_loss_mid_chunk_keeps_the_outcome_unknown() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut request = [0; 4096];
        let _ = socket.read(&mut request).await;
        socket.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/event-stream\r\n\r\nA\r\ndata: {}\n\n\r\n").await.unwrap();
    });
    let upstream = crate::engine::EngineUpstream {
        host_port: port,
        api_key: String::new(),
        model_id: "test".into(),
        served_name: "test".into(),
    };
    let (_, _, result) = collect(upstream, true).await;
    assert!(result.is_err());
    server.await.unwrap();
}
#[tokio::test]
async fn slow_consumer_backpressures_the_bounded_channel_then_recovers() {
    let mut chunk = b"data: ".to_vec();
    chunk.extend(vec![b'x'; 64 * 1024]);
    chunk.extend_from_slice(b"\n\n");
    let mut chunks = vec![chunk; 16];
    chunks.push(b"data: [DONE]\n\n".to_vec());
    let (upstream, server) = server(StatusCode::OK, chunks).await;
    let (tx, mut rx) = tokio::sync::mpsc::channel(4);
    let (head_tx, head_rx) = tokio::sync::oneshot::channel();
    let worker = tokio::spawn(run_terminal(upstream, vec![], true, tx, head_tx));
    assert_eq!(head_rx.await.unwrap(), (StatusCode::OK, true));
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(!worker.is_finished());
    assert!(rx.len() <= 4);
    while rx.recv().await.is_some() {}
    assert_eq!(worker.await.unwrap(), Ok((true, true)));
    server.abort();
}
#[test]
fn physical_ingress_requires_selected_on_link_backed_interface() {
    let root = tempfile::tempdir().unwrap();
    let iface = root.path().join("eth0");
    std::fs::create_dir_all(iface.join("device")).unwrap();
    std::fs::write(iface.join("type"), "1").unwrap();
    std::fs::write(iface.join("operstate"), "up").unwrap();
    assert!(physical_route_document(
        br#"[{"dev":"eth0","dst":"192.168.1.2"}]"#,
        root.path()
    ));
    for value in [
        json!([{"dev":"tailscale0"}]),
        json!([{"dev":"eth0","gateway":"192.168.1.1"}]),
        json!([{"dev":"../eth0"}]),
        json!([{"dev":"eth0","type":"local"}]),
        json!([]),
    ] {
        assert!(!physical_route_document(
            &serde_json::to_vec(&value).unwrap(),
            root.path()
        ));
    }
}
