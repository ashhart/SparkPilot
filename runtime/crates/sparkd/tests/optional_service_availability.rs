//! Optional gateway or access-proxy port conflicts must leave health, pairing and the node management API available.

use std::io::{BufRead, BufReader, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct Daemon {
    child: Child,
}

impl Daemon {
    fn start(
        data_dir: &std::path::Path,
        address: SocketAddr,
        recipe: &std::path::Path,
        root_key: &std::path::Path,
    ) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_sparkd"));
        command
            .arg("--listen")
            .arg(address.to_string())
            .arg("--data-dir")
            .arg(data_dir)
            .arg("--node-name")
            .arg("optional-service-test")
            .arg("--no-advertise")
            .arg("--no-tls")
            .arg("--engine-backend")
            .arg("mock")
            .arg("--optional-service-recipe")
            .arg(recipe)
            .arg("--optional-service-root-key")
            .arg(root_key)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        Self {
            child: command.spawn().expect("start sparkd"),
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn unused_address() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind test port");
    listener.local_addr().expect("test port address")
}

/// Plain-HTTP health poll. Returns false if the daemon never answers.
fn serves_health(address: SocketAddr, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        let Ok(mut stream) = TcpStream::connect_timeout(&address, Duration::from_millis(100))
        else {
            std::thread::sleep(Duration::from_millis(25));
            continue;
        };
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        if stream
            .write_all(
                format!(
                    "GET /api/v1/health HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\n\r\n"
                )
                .as_bytes(),
            )
            .is_err()
        {
            std::thread::sleep(Duration::from_millis(25));
            continue;
        }
        let mut status = String::new();
        if BufReader::new(&stream).read_line(&mut status).is_ok() && status.contains("200") {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    false
}

#[test]
fn a_squatted_optional_service_port_does_not_stop_the_node_api() {
    // Occupy the fixed gateway port to exercise an existing-service conflict.
    let squatter = TcpListener::bind((
        std::net::Ipv4Addr::LOCALHOST,
        spark_privd::backend::OPEN_WEBUI_GATEWAY_PORT,
    ))
    .expect("hold the optional-service gateway port");

    let directory = tempfile::tempdir().expect("temp dir");
    let address = unused_address();
    let repository = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let _daemon = Daemon::start(
        directory.path(),
        address,
        &repository.join("recipes/open-webui.service.json"),
        &repository.join("packaging/trust/service-root.pub"),
    );

    assert!(
        serves_health(address, Duration::from_secs(10)),
        "the node API must still serve health when an optional service cannot bind its port"
    );

    drop(squatter);
}

#[test]
fn missing_optional_service_package_files_do_not_stop_the_node_api() {
    let directory = tempfile::tempdir().expect("temp dir");
    let address = unused_address();
    let _daemon = Daemon::start(
        directory.path(),
        address,
        &directory.path().join("missing-service-recipe.json"),
        &directory.path().join("missing-service-root.pub"),
    );

    assert!(
        serves_health(address, Duration::from_secs(10)),
        "the node API must remain available without optional-service package material"
    );
}
