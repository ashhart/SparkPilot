use super::*;

#[test]
fn completion_scanning_accepts_sse_line_endings_across_chunk_boundaries() {
    for ending in ["\n", "\r\n", "\r"] {
        let stream = format!(
            "data: {{\"choices\":[{{\"delta\":{{\"content\":\"answer\"}}}}]}}{ending}{ending}\
             data: {{\"usage\":{{\"prompt_tokens\":12,\"completion_tokens\":14,\"total_tokens\":26}}}}{ending}{ending}\
             data: [DONE]{ending}{ending}"
        );
        for split in 0..=stream.len() {
            let mut scanner = UsageScanner::default();
            scanner.scan_frame(&stream.as_bytes()[..split]);
            scanner.scan_frame(&stream.as_bytes()[split..]);
            assert!(
                scanner.completed,
                "missing terminal marker for {ending:?} at {split}"
            );
            assert!(scanner.saw_output);
            assert!(!scanner.failed);
            assert_eq!(scanner.total_tokens(), Some(26));
        }
    }
}

#[test]
fn completion_scanning_ignores_non_data_sse_lines() {
    let mut scanner = UsageScanner::default();
    scanner.scan_frame(b"{\"usage\":{\"total_tokens\":99}}\n[DONE]\n\n");
    assert_eq!(
        scanner.total_tokens(),
        None,
        "unknown SSE fields cannot supply usage"
    );
    assert!(
        !scanner.completed,
        "unknown SSE fields cannot complete a request"
    );
}

/// A recorder that charges one guest's day, with the schema the charge is written into.
fn guest_recorder() -> (
    Arc<parking_lot::Mutex<rusqlite::Connection>>,
    UsageRecorder,
    uuid::Uuid,
) {
    let mut connection = rusqlite::Connection::open_in_memory().expect("memory database");
    crate::migration::migrate(&mut connection).expect("migrate");
    let device_id = uuid::Uuid::new_v4();
    crate::store::insert_device(
        &connection,
        &device_id,
        "guest device",
        "ios",
        b"spki",
        "fingerprint",
        "observer",
    )
    .expect("insert device");
    let db = Arc::new(parking_lot::Mutex::new(connection));
    let recorder = UsageRecorder {
        reservation: None,
        db: db.clone(),
        consent: Arc::new(parking_lot::RwLock::new(
            crate::appliance_api::TelemetryConsentConfig::default(),
        )),
        clock: Arc::new(crate::clock::SystemUtcClock),
        device_id: device_id.to_string(),
        model_id: "qwen3-8b".to_owned(),
        guest: Some((device_id, "2026-09-05".to_owned())),
    };
    (db, recorder, device_id)
}

fn guest_day(
    db: &Arc<parking_lot::Mutex<rusqlite::Connection>>,
    device_id: &uuid::Uuid,
) -> (i64, i64) {
    let conn = db.lock();
    conn.query_row(
        "SELECT requests, prompt_tokens + completion_tokens FROM guest_usage WHERE device_id = ?1",
        rusqlite::params![device_id.to_string()],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .unwrap_or((0, 0))
}

fn frames(count: usize, text: &str) -> Vec<Result<Bytes, reqwest::Error>> {
    (0..count)
        .map(|_| {
            Ok(Bytes::from(format!(
                "data: {{\"choices\":[{{\"delta\":{{\"content\":\"{text}\"}}}}]}}\n\n"
            )))
        })
        .collect()
}

/// BH-10: a stream the caller walks away from was still served, so it is still charged.
#[tokio::test]
async fn an_aborted_stream_still_charges_the_guests_day() {
    let (db, recorder, device_id) = guest_recorder();
    let mut tee = UsageTee {
        frames: futures::stream::iter(frames(8, "hello there")),
        guest_slot: None,
        ticket: None,
        scanner: UsageScanner::default(),
        recorder: Some(recorder),
        first: true,
        peer_loss_emitted: false,
        attempt: None,
        prompt_bytes: 4_000,
        completion_bytes: 0,
        chunks: 0,
        timings: None,
    };
    // Read a couple of frames and reset the connection, which is what an abort looks like here.
    assert!(tee.next().await.is_some());
    assert!(tee.next().await.is_some());
    drop(tee);

    let (requests, tokens) = guest_day(&db, &device_id);
    assert_eq!(requests, 1, "an aborted stream is still one served request");
    assert!(
        tokens >= 1_000,
        "an aborted stream charged {tokens} tokens; its prompt alone was 4000 bytes"
    );
}

/// BH-07: a stream that carried no usage chunk is charged a stand-in rather than nothing.
#[tokio::test]
async fn a_stream_with_no_usage_chunk_is_charged_a_stand_in() {
    let (db, recorder, device_id) = guest_recorder();
    let mut tee = UsageTee {
        frames: futures::stream::iter(frames(3, "hello")),
        guest_slot: None,
        ticket: None,
        scanner: UsageScanner::default(),
        recorder: Some(recorder),
        first: true,
        peer_loss_emitted: false,
        attempt: None,
        prompt_bytes: 4_000,
        completion_bytes: 0,
        chunks: 0,
        timings: None,
    };
    while tee.next().await.is_some() {}
    drop(tee);

    let (requests, tokens) = guest_day(&db, &device_id);
    assert_eq!(requests, 1);
    assert!(
        tokens > 0,
        "a stream with no usage chunk was charged {tokens} tokens"
    );
}

/// Reported usage is never replaced by the stand-in.
#[tokio::test]
async fn reported_usage_is_charged_exactly_as_reported() {
    let (db, recorder, device_id) = guest_recorder();
    let mut chunks = frames(1, "hi");
    chunks.push(Ok(Bytes::from(
        "data: {\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":14,\"total_tokens\":26}}\n\n",
    )));
    chunks.push(Ok(Bytes::from("data: [DONE]\n\n")));
    let mut tee = UsageTee {
        frames: futures::stream::iter(chunks),
        guest_slot: None,
        ticket: None,
        scanner: UsageScanner::default(),
        recorder: Some(recorder),
        first: true,
        peer_loss_emitted: false,
        attempt: None,
        prompt_bytes: 40_000,
        completion_bytes: 0,
        chunks: 0,
        timings: None,
    };
    while tee.next().await.is_some() {}
    drop(tee);

    let (requests, tokens) = guest_day(&db, &device_id);
    assert_eq!(requests, 1);
    assert_eq!(
        tokens, 26,
        "reported counts stand, whatever the byte estimate"
    );
}

#[test]
fn anthropic_usage_joins_input_and_output_and_requires_a_terminal_marker() {
    let frames = concat!(
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12,\"output_tokens\":0}}}\n\n",
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"read\",\"input\":{}}}\n\n",
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n",
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":14}}\n\n"
    );
    for split in 0..=frames.len() {
        let mut scanner = UsageScanner::default();
        scanner.scan_frame(&frames.as_bytes()[..split]);
        scanner.scan_frame(&frames.as_bytes()[split..]);
        assert!(scanner.saw_output);
        assert!(!scanner.completed);
        assert_eq!(scanner.total_tokens(), Some(26));
        assert!(scanner.usage.precise_counts);
        scanner.scan_frame(b"data: {\"type\":\"message_stop\"}\n\n");
        assert!(scanner.completed);
        assert!(!scanner.failed);
    }
}

#[test]
fn anthropic_stop_without_usage_or_reason_is_not_a_verified_completion() {
    let mut scanner = UsageScanner::default();
    scanner.scan_frame(b"data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12,\"output_tokens\":0}}}\n\n");
    scanner.scan_frame(
        b"data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"answer\"}}\n\n",
    );
    scanner.scan_frame(b"data: {\"type\":\"message_stop\"}\n\n");
    assert!(scanner.completed && scanner.failed);
    assert!(!scanner.usage.precise_counts);
}
