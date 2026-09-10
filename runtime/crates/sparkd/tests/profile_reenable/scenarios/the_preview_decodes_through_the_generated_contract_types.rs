/// Decode full previews through generated types to catch guard diagnostics incorrectly widening the closed admission enum.
#[tokio::test]
async fn the_preview_decodes_through_the_generated_contract_types() {
    let peer = peer("owner");
    disable_profile(&peer);
    let preview = issue_preview(&peer).await;

    let decoded: spark_contracts::generated::ModelActionPreview =
        serde_json::from_value(preview.clone()).unwrap_or_else(|error| {
            panic!("the preview is not contract-shaped: {error}\n{preview:#}")
        });

    assert!(matches!(
        decoded.action,
        spark_contracts::generated::ModelActionPreviewAction::ProfileReenable
    ));
    // Keep the typed admission decision within its enum and expose open-ended diagnostics separately.
    assert!(matches!(
        decoded.evidence.memory_admission,
        Some(spark_contracts::generated::ModelActionPreviewEvidenceMemoryAdmission::DenyProfileUnsafe)
    ));
    assert_eq!(
        decoded.evidence.profile_failure_code.as_deref(),
        Some("MEMORY_PRESSURE_CRITICAL")
    );
}
