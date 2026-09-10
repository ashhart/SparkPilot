async fn clustered_harness(
    available_bytes: u64,
) -> (Harness, SocketAddr, p256::ecdsa::SigningKey, uuid::Uuid) {
    harness_with_policy(available_bytes, system_clock(), Duration::ZERO, true, None).await
}
