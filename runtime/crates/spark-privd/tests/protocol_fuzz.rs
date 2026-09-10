//! Exercise parser panic resistance and bounded errors with deterministic random and adversarial frames.

use spark_privd::protocol::{MAX_REQUEST_BYTES, parse_request};

/// Deterministic 64-bit LCG (same sequence every run).
struct Lcg(u64);

impl Lcg {
    fn next_u64(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0
    }

    fn bytes(&mut self, out: &mut [u8]) {
        for chunk in out.chunks_mut(8) {
            let value = self.next_u64().to_be_bytes();
            chunk.copy_from_slice(&value[..chunk.len()]);
        }
    }
}

/// Require panic-free parsing and a request ID on every accepted operation.
fn exercise(input: &[u8]) {
    if let Ok(operation) = parse_request(input) {
        assert!(
            !operation.request_id().is_nil(),
            "parsed operation must carry a request id"
        );
    }
}

#[test]
fn structured_corpus_never_panics() {
    // Adversarial / structural inputs.
    let mut corpus: Vec<Vec<u8>> = vec![
        vec![],                                                // empty
        vec![0, 0, 0, 0],                                      // empty payload
        vec![0xff, 0xff, 0xff, 0xff],                          // oversized declaration
        vec![0, 0, 0, 0x7f],                                   // large declared length
        vec![b'{', b'}'],                                      // missing header
        (MAX_REQUEST_BYTES as u32 + 1).to_be_bytes().to_vec(), // header alone, too big
        (4u32)
            .to_be_bytes()
            .into_iter()
            .chain(b"oooo".iter().copied())
            .collect(), // json garbage
        b"{\"operation\":\"probe_container_runtime\",\"request_id\":\"not-a-uuid\"}".to_vec(),
        (20u32)
            .to_be_bytes()
            .into_iter()
            .chain(b"{\"operation\":\"x\"}".iter().copied())
            .collect(), // unknown tag
        b"{\"operation\":\"run_shell\",\"command\":\"rm -rf /\"}".to_vec(), // forbidden design must not parse
    ];
    // Truncations of a valid request at every prefix.
    let mut valid = Vec::new();
    let op = spark_privd::PrivilegedOperation::Reboot {
        request_id: uuid::Uuid::new_v4(),
    };
    let payload = serde_json::to_vec(&op).unwrap();
    valid.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    valid.extend_from_slice(&payload);
    for cut in 0..valid.len() {
        corpus.push(valid[..cut].to_vec());
    }
    // Length-prefix lies.
    corpus.push({
        let mut lying = (5u32).to_be_bytes().to_vec();
        lying.extend_from_slice(&valid);
        lying
    });

    for input in corpus {
        exercise(&input);
    }
}

#[test]
fn lcg_random_inputs_never_panic() {
    let mut rng = Lcg(0x9e3779b97f4a7c15);
    for _ in 0..50_000 {
        let mut input = vec![0u8; (rng.next_u64() % 128) as usize];
        rng.bytes(&mut input);
        exercise(&input);
    }
}

// Rejected or truncated frames must never reach execution and must produce bounded responses.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicUsize, Ordering};

use spark_privd::backend::{BackendError, OpBackend};
use spark_privd::protocol::{PrivilegedResponse, RequestIdTracker};

/// A backend that refuses to do anything and counts being asked.
#[derive(Default)]
struct CountingBackend {
    calls: AtomicUsize,
}

impl OpBackend for CountingBackend {
    fn execute(
        &self,
        operation: &spark_privd::PrivilegedOperation,
    ) -> Result<PrivilegedResponse, BackendError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(PrivilegedResponse::rejected(
            operation.request_id(),
            "not_executed",
            "the fuzz backend performs no work",
        ))
    }
}

/// One framed request, ready for the wire.
fn frame(payload: &[u8]) -> Vec<u8> {
    let mut out = (payload.len() as u32).to_be_bytes().to_vec();
    out.extend_from_slice(payload);
    out
}

/// A valid request the helper would accept, as bytes.
fn valid_frame() -> Vec<u8> {
    let operation = spark_privd::PrivilegedOperation::Reboot {
        request_id: uuid::Uuid::from_u128(0x9c1d_2e3f_4a5b_6c7d_8e9f_0a1b_2c3d_4e5f),
    };
    frame(&serde_json::to_vec(&operation).unwrap())
}

/// Write and read on separate threads to avoid deadlock on truncated frames or full socket buffers.
fn drive(frames: &[Vec<u8>]) -> (Vec<PrivilegedResponse>, usize) {
    let (client, server) = UnixStream::pair().expect("socket pair");
    let backend = std::sync::Arc::new(CountingBackend::default());
    let handler = {
        let backend = backend.clone();
        std::thread::spawn(move || {
            let mut tracker = RequestIdTracker::default();
            let uid = unsafe { libc::geteuid() };
            spark_privd::server::handle_connection(server, uid, backend.as_ref(), &mut tracker);
        })
    };

    let mut reader = client.try_clone().expect("clone socket");
    let collector = std::thread::spawn(move || {
        let mut responses = Vec::new();
        loop {
            let mut header = [0u8; 4];
            if reader.read_exact(&mut header).is_err() {
                return responses;
            }
            let length = u32::from_be_bytes(header) as usize;
            assert!(
                length <= MAX_REQUEST_BYTES,
                "the helper wrote a {length} byte response"
            );
            let mut payload = vec![0u8; length];
            reader.read_exact(&mut payload).expect("read response");
            responses.push(serde_json::from_slice(&payload).expect("response json"));
        }
    });

    let mut writer = client;
    for bytes in frames {
        if writer.write_all(bytes).is_err() {
            break;
        }
    }
    writer.flush().ok();
    // The helper may already have closed the connection, which makes the half close moot rather than a failure.
    let _ = writer.shutdown(std::net::Shutdown::Write);
    let responses = collector.join().expect("collector thread");
    handler.join().expect("handler thread");
    (responses, backend.calls.load(Ordering::SeqCst))
}

/// Use self-consistent frame lengths so each malformed payload receives a bounded rejection without reaching the backend.
#[test]
fn a_rejected_frame_never_reaches_the_backend() {
    let mut rng = Lcg(0x1234_5678_9abc_def0);
    let mut frames = Vec::new();
    for index in 0..2_000 {
        let mut payload = vec![0u8; (rng.next_u64() % 96) as usize];
        rng.bytes(&mut payload);
        match index % 4 {
            // Random bytes as a payload.
            0 => {}
            // JSON that is not an operation.
            1 => payload = format!("{{\"operation\":\"{index}\"}}").into_bytes(),
            // A known tag with the wrong fields.
            2 => payload = br#"{"operation":"reboot","request_id":"not-a-uuid"}"#.to_vec(),
            // An operation the protocol has no representation for.
            _ => payload = br#"{"operation":"run_shell","command":"rm -rf /"}"#.to_vec(),
        }
        frames.push(frame(&payload));
    }
    for case in helper_regressions() {
        // Test inconsistent lengths on separate connections so they cannot desynchronize the shared stream.
        if is_self_consistent(&case) {
            frames.push(case);
        }
    }

    let (responses, calls) = drive(&frames);
    assert_eq!(calls, 0, "a rejected frame reached the privileged backend");
    assert_eq!(responses.len(), frames.len(), "a frame went unanswered");
    for response in &responses {
        assert!(!response.accepted, "a malformed frame was accepted");
        assert!(
            response.message.len() < 128,
            "the helper answered with a {} byte message",
            response.message.len()
        );
        assert!(
            response.code == "protocol_error" || response.code == "invalid_request",
            "unexpected refusal code {}",
            response.code
        );
    }
}

/// Test each truncated prefix on a fresh connection because incomplete frames have no safe resume point.
#[test]
fn no_truncation_of_a_valid_request_is_executed() {
    let valid = valid_frame();
    for cut in 0..valid.len() {
        let (responses, calls) = drive(&[valid[..cut].to_vec()]);
        assert_eq!(
            calls,
            0,
            "a request truncated at {cut} of {} bytes was executed",
            valid.len()
        );
        for response in responses {
            assert!(!response.accepted);
        }
    }
    // Verify the complete frame executes so rejection is specific to truncation.
    let (_, calls) = drive(&[valid]);
    assert_eq!(calls, 1, "the complete request was not executed");
}

/// Test each declared-length boundary on its own connection to bound reads.
#[test]
fn every_declared_length_edge_is_refused_without_work() {
    let payload = br#"{"operation":"probe_container_runtime","request_id":"00000000-0000-4000-8000-000000000001"}"#;
    let edges: Vec<Vec<u8>> = vec![
        // Header alone.
        vec![0, 0, 0, 1],
        // Length above the cap, with nothing behind it.
        u32::MAX.to_be_bytes().to_vec(),
        (MAX_REQUEST_BYTES as u32 + 1).to_be_bytes().to_vec(),
        // A maximum-length declaration with a closed empty stream must terminate rather than hang.
        (MAX_REQUEST_BYTES as u32).to_be_bytes().to_vec(),
        // One byte short and one byte long of the truth.
        {
            let mut lying = ((payload.len() - 1) as u32).to_be_bytes().to_vec();
            lying.extend_from_slice(payload);
            lying
        },
        {
            let mut lying = ((payload.len() + 1) as u32).to_be_bytes().to_vec();
            lying.extend_from_slice(payload);
            lying
        },
        // Zero length, then a valid payload that is now orphaned.
        {
            let mut zero = 0u32.to_be_bytes().to_vec();
            zero.extend_from_slice(payload);
            zero
        },
    ];
    for (index, edge) in edges.iter().enumerate() {
        let (responses, calls) = drive(std::slice::from_ref(edge));
        assert_eq!(calls, 0, "length edge {index} reached the backend");
        for response in responses {
            assert!(!response.accepted, "length edge {index} was accepted");
            assert!(response.message.len() < 128);
        }
    }
}

/// An oversized declaration leaves its payload on the wire; the helper answers once and closes rather than parsing the payload as frames.
#[test]
fn an_oversized_declaration_closes_the_connection_before_any_following_frame() {
    let mut oversized = (MAX_REQUEST_BYTES as u32 + 1).to_be_bytes().to_vec();
    // The payload is made of valid frames so a desynchronised reader would execute one of them.
    while oversized.len() < MAX_REQUEST_BYTES + 1 + 4 {
        oversized.extend_from_slice(&valid_frame());
    }
    let (responses, calls) = drive(&[oversized, valid_frame()]);
    assert_eq!(
        calls, 0,
        "a frame after an oversized declaration was executed"
    );
    assert_eq!(
        responses.len(),
        1,
        "the helper kept reading after the oversized declaration"
    );
    assert_eq!(responses[0].code, "protocol_error");
}

/// Reject repeated request IDs before backend execution so retries cannot repeat privileged effects.
#[test]
fn a_replayed_request_id_is_executed_once() {
    let valid = valid_frame();
    let (responses, calls) = drive(&[valid.clone(), valid]);
    assert_eq!(calls, 1, "a replayed request id ran twice");
    assert_eq!(responses.len(), 2);
    assert_eq!(responses[1].code, "duplicate_request");
}

/// Whether a frame's declared length matches the bytes that follow it.
fn is_self_consistent(frame: &[u8]) -> bool {
    if frame.len() < 4 {
        return false;
    }
    let declared = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
    declared == frame.len() - 4
}

/// The committed helper frames, replayed exactly.
fn helper_regressions() -> Vec<Vec<u8>> {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../tests/security/fuzz/regressions.json");
    let text = std::fs::read_to_string(&path).expect("regression corpus");
    let document: serde_json::Value = serde_json::from_str(&text).expect("regression json");
    document["helper_frames"]
        .as_array()
        .expect("helper_frames")
        .iter()
        .map(|entry| {
            assert!(
                entry["why"].as_str().is_some_and(|why| !why.is_empty()),
                "every regression case must say what it caught"
            );
            hex::decode(entry["hex"].as_str().expect("hex")).expect("hex bytes")
        })
        .collect()
}

/// Every committed frame, whatever its shape, is refused without work.
#[test]
fn every_committed_regression_frame_is_refused_without_work() {
    for (index, case) in helper_regressions().into_iter().enumerate() {
        let (responses, calls) = drive(&[case]);
        assert_eq!(calls, 0, "regression frame {index} reached the backend");
        for response in responses {
            assert!(!response.accepted, "regression frame {index} was accepted");
        }
    }
}
