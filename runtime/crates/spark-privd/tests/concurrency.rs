//! Socket-level concurrency regressions for the privileged helper.

use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::time::Duration;

use spark_privd::backend::{BackendError, OpBackend};
use spark_privd::protocol::{
    PrivilegedOperation, PrivilegedResponse, read_response, write_request,
};

fn current_euid() -> u32 {
    unsafe { libc::geteuid() }
}

fn request(
    path: &std::path::Path,
    operation: &PrivilegedOperation,
) -> Result<PrivilegedResponse, String> {
    let mut stream = std::os::unix::net::UnixStream::connect(path)
        .map_err(|error| format!("connect: {error}"))?;
    write_request(&mut stream, operation).map_err(|error| format!("write: {error}"))?;
    read_response(&mut stream).map_err(|error| format!("read: {error}"))
}

#[derive(Default)]
struct BlockingUpdateBackend {
    update_gate: (Mutex<UpdateGate>, Condvar),
}

#[derive(Default)]
struct UpdateGate {
    started: bool,
    released: bool,
}

impl BlockingUpdateBackend {
    fn wait_until_update_started(&self) {
        let (state, changed) = &self.update_gate;
        let state = state.lock().expect("update gate");
        let (state, timeout) = changed
            .wait_timeout_while(state, Duration::from_secs(2), |state| !state.started)
            .expect("update gate wait");
        assert!(state.started, "update request never reached the backend");
        assert!(!timeout.timed_out(), "update request start timed out");
    }

    fn release_update(&self) {
        let (state, changed) = &self.update_gate;
        state.lock().expect("update gate").released = true;
        changed.notify_all();
    }
}

impl OpBackend for BlockingUpdateBackend {
    fn execute(&self, operation: &PrivilegedOperation) -> Result<PrivilegedResponse, BackendError> {
        if matches!(operation, PrivilegedOperation::InstallSystemUpdates { .. }) {
            let (state, changed) = &self.update_gate;
            let mut state = state.lock().expect("update gate");
            state.started = true;
            changed.notify_all();
            while !state.released {
                state = changed.wait(state).expect("update release wait");
            }
        }

        Ok(PrivilegedResponse {
            request_id: operation.request_id(),
            accepted: true,
            code: operation.kind().into(),
            message: "test operation completed".into(),
            details: serde_json::Value::Null,
        })
    }
}

#[test]
fn emergency_request_is_served_while_an_update_is_still_running() {
    let directory = tempfile::tempdir().expect("socket tempdir");
    let socket_path = directory.path().join("spark-privd.sock");
    let listener = spark_privd::server::bind_socket(&socket_path).expect("bind socket");
    let backend = Arc::new(BlockingUpdateBackend::default());
    let server_backend = backend.clone();
    std::thread::spawn(move || {
        let _ = spark_privd::server::serve(listener, current_euid(), server_backend.as_ref());
    });

    let update_path = socket_path.clone();
    let update = std::thread::spawn(move || {
        request(
            &update_path,
            &PrivilegedOperation::InstallSystemUpdates {
                request_id: uuid::Uuid::new_v4(),
                system_packages: true,
                firmware: true,
            },
        )
    });
    backend.wait_until_update_started();

    let (emergency_tx, emergency_rx) = mpsc::channel();
    let emergency_path = socket_path.clone();
    let emergency = std::thread::spawn(move || {
        let outcome = request(
            &emergency_path,
            &PrivilegedOperation::StopModel {
                request_id: uuid::Uuid::new_v4(),
                instance_id: uuid::Uuid::new_v4(),
                force: true,
            },
        );
        let _ = emergency_tx.send(outcome);
    });

    let (confirmation_tx, confirmation_rx) = mpsc::channel();
    let confirmation_path = socket_path.clone();
    let confirmation = std::thread::spawn(move || {
        let outcome = request(
            &confirmation_path,
            &PrivilegedOperation::ConfirmNetworkChange {
                request_id: uuid::Uuid::new_v4(),
                configuration_id: uuid::Uuid::new_v4(),
            },
        );
        let _ = confirmation_tx.send(outcome);
    });

    let emergency_outcome = emergency_rx.recv_timeout(Duration::from_millis(500));
    let confirmation_outcome = confirmation_rx.recv_timeout(Duration::from_millis(500));
    backend.release_update();
    update
        .join()
        .expect("update client")
        .expect("update response");
    emergency.join().expect("emergency client");
    confirmation.join().expect("network confirmation client");

    let response = emergency_outcome
        .expect("emergency stop was blocked behind the update")
        .expect("emergency stop response");
    assert!(response.accepted);
    assert_eq!(response.code, "stop_model");

    let response = confirmation_outcome
        .expect("network failsafe confirmation was blocked behind the update")
        .expect("network confirmation response");
    assert!(response.accepted);
    assert_eq!(response.code, "confirm_network_change");
}
