async fn harness_with_clock(
    available_bytes: u64,
    clock: Arc<dyn UtcClock>,
) -> (Harness, SocketAddr, p256::ecdsa::SigningKey, uuid::Uuid) {
    harness_with_policy(available_bytes, clock, Duration::ZERO, false, None).await
}
