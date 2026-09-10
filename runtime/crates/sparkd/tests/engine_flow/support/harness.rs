struct Harness {
    state: AppState,
    available: Arc<AtomicU64>,
    backend: Arc<MockVllmBackend>,
    engine: Arc<EngineManager>,
    download_starts: Arc<AtomicU64>,
    privileged_operations: Option<Arc<std::sync::Mutex<Vec<String>>>>,
    _dir: tempfile::TempDir,
}

/// Serve signed HTTP with identity, migrations, installed recipe and the real engine manager over a mock backend.
async fn harness(
    available_bytes: u64,
) -> (Harness, SocketAddr, p256::ecdsa::SigningKey, uuid::Uuid) {
    harness_with_policy(available_bytes, system_clock(), Duration::ZERO, false, None).await
}
