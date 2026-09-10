use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, ClientConnection, DigitallySignedStruct, SignatureScheme, StreamOwned};
use serde_json::Value;
use sha2::{Digest, Sha256};

#[derive(Debug, Default)]
struct CapturingVerifier {
    leaf: Mutex<Option<Vec<u8>>>,
}

impl ServerCertVerifier for CapturingVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        *self.leaf.lock().expect("leaf capture lock") = Some(end_entity.as_ref().to_vec());
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::ED25519,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
        ]
    }
}

struct Daemon {
    child: Child,
}

impl Daemon {
    fn start(data_dir: &std::path::Path, address: SocketAddr, no_tls: bool) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_sparkd"));
        command
            .arg("--listen")
            .arg(address.to_string())
            .arg("--data-dir")
            .arg(data_dir)
            .arg("--node-name")
            .arg("restart-test")
            .arg("--no-advertise")
            .arg("--engine-backend")
            .arg("mock")
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if no_tls {
            command.arg("--no-tls");
        }
        Self {
            child: command.spawn().expect("start sparkd"),
        }
    }

    fn stop(mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
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

fn fetch_health_and_leaf(address: SocketAddr) -> (Value, Vec<u8>) {
    let deadline = Instant::now() + Duration::from_secs(8);
    let verifier = Arc::new(CapturingVerifier::default());
    let mut config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(verifier.clone())
        .with_no_client_auth();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    let config = Arc::new(config);

    loop {
        if Instant::now() >= deadline {
            panic!("sparkd did not serve TLS health before the deadline");
        }
        let Ok(tcp) = TcpStream::connect_timeout(&address, Duration::from_millis(100)) else {
            std::thread::sleep(Duration::from_millis(25));
            continue;
        };
        tcp.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        tcp.set_write_timeout(Some(Duration::from_secs(1))).unwrap();
        let server_name = ServerName::try_from("spark.local")
            .expect("valid test server name")
            .to_owned();
        let connection = ClientConnection::new(config.clone(), server_name).expect("TLS client");
        let mut stream = StreamOwned::new(connection, tcp);
        if stream
            .write_all(
                b"GET /api/v1/health HTTP/1.1\r\nHost: spark.local\r\nConnection: close\r\n\r\n",
            )
            .is_err()
        {
            continue;
        }
        let mut response = Vec::new();
        if stream.read_to_end(&mut response).is_err() {
            continue;
        }
        let Some(separator) = response.windows(4).position(|window| window == b"\r\n\r\n") else {
            continue;
        };
        if !response.starts_with(b"HTTP/1.1 200") {
            continue;
        }
        let health: Value =
            serde_json::from_slice(&response[separator + 4..]).expect("health JSON");
        let leaf = verifier
            .leaf
            .lock()
            .expect("leaf capture lock")
            .clone()
            .expect("server leaf captured");
        return (health, leaf);
    }
}

fn fetch_plain_health(address: SocketAddr) -> Value {
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        if Instant::now() >= deadline {
            panic!("sparkd did not serve plain health before the deadline");
        }
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
                b"GET /api/v1/health HTTP/1.1\r\nHost: spark.local\r\nConnection: close\r\n\r\n",
            )
            .is_err()
        {
            continue;
        }
        let mut response = Vec::new();
        if stream.read_to_end(&mut response).is_err() {
            continue;
        }
        let Some(separator) = response.windows(4).position(|window| window == b"\r\n\r\n") else {
            continue;
        };
        if response.starts_with(b"HTTP/1.1 200") {
            return serde_json::from_slice(&response[separator + 4..]).expect("health JSON");
        }
    }
}

#[test]
fn same_data_directory_preserves_node_and_wire_tls_identity() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let data_dir = tempfile::tempdir().expect("runtime data directory");
    let address = unused_address();

    let first = Daemon::start(data_dir.path(), address, false);
    let (first_health, first_leaf) = fetch_health_and_leaf(address);
    first.stop();

    let identity_directory = data_dir.path().join("identity");
    let persisted =
        sparkd::tls::load_or_create(&identity_directory).expect("persisted TLS identity");
    assert!(!persisted.created);
    assert_eq!(persisted.certificate_der, first_leaf);
    assert_eq!(
        persisted.fingerprint,
        hex::encode(Sha256::digest(&first_leaf))
    );
    let key_mode = std::fs::metadata(identity_directory.join(sparkd::tls::PRIVATE_KEY_FILE_NAME))
        .expect("persisted private key")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(key_mode, 0o600);

    let second = Daemon::start(data_dir.path(), address, false);
    let (second_health, second_leaf) = fetch_health_and_leaf(address);
    second.stop();

    assert_eq!(first_health["node_id"], second_health["node_id"]);
    assert_eq!(
        hex::encode(Sha256::digest(&first_leaf)),
        hex::encode(Sha256::digest(&second_leaf)),
        "the exact leaf DER fingerprint must survive a daemon restart"
    );
    assert_eq!(first_leaf, second_leaf, "the exact wire leaf must persist");
}

#[test]
fn explicit_no_tls_mode_creates_no_certificate_or_private_key() {
    let data_dir = tempfile::tempdir().expect("runtime data directory");
    let address = unused_address();
    let daemon = Daemon::start(data_dir.path(), address, true);
    let health = fetch_plain_health(address);
    daemon.stop();

    assert!(health["node_id"].is_string());
    let identity_directory = data_dir.path().join("identity");
    assert!(
        !identity_directory
            .join(sparkd::tls::CERTIFICATE_FILE_NAME)
            .exists()
    );
    assert!(
        !identity_directory
            .join(sparkd::tls::PRIVATE_KEY_FILE_NAME)
            .exists()
    );
}
