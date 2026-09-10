async fn harness_with_external_engine(
    available_bytes: u64,
) -> (Harness, SocketAddr, p256::ecdsa::SigningKey, uuid::Uuid) {
    harness_with_policy(
        available_bytes,
        system_clock(),
        Duration::ZERO,
        false,
        Some(ObservedWorkloads {
            containers: vec![ObservedContainer {
                id: "1a3b".into(),
                name: Some("existing-vllm".into()),
                state: "running".into(),
                image: Some("vllm/vllm-openai:v0.11.0".into()),
                ports: vec![ObservedPort {
                    host_ip: "0.0.0.0".into(),
                    host_port: 8000,
                    container_port: 8000,
                    protocol: "tcp".into(),
                }],
            }],
            truncated: false,
            unreadable_lines: 0,
        }),
    )
    .await
}
