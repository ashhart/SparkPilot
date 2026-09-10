use spark_privd::backend::FakeBackend;
use spark_privd::protocol::{PrivilegedOperation, RequestIdTracker};
use sparkd::privd::PrivilegedClient;
use std::time::Duration;

#[test]
fn the_privileged_client_reconnects_after_the_helper_socket_is_replaced() {
    let directory = tempfile::tempdir().unwrap();
    let socket = directory.path().join("helper.sock");
    let client = PrivilegedClient::new(&socket);
    let operation = || PrivilegedOperation::ProbeContainerRuntime {
        request_id: uuid::Uuid::new_v4(),
    };
    for _ in 0..2 {
        assert!(
            client
                .call_bounded(operation(), Duration::from_secs(1))
                .is_err()
        );
        let listener = spark_privd::server::bind_socket(&socket).unwrap();
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            spark_privd::server::handle_connection(
                stream,
                unsafe { libc::geteuid() },
                &FakeBackend::default(),
                &mut RequestIdTracker::new(),
            );
        });
        assert!(
            client
                .call_bounded(operation(), Duration::from_secs(1))
                .unwrap()
                .accepted
        );
        server.join().unwrap();
        std::fs::remove_file(&socket).unwrap();
    }
}
