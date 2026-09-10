#[tokio::test]
async fn unpinned_image_recipe_is_rejected_even_if_signed() {
    // Reject structurally invalid unpinned images even when the catalogue signature verifies.
    let dir = tempfile::tempdir().unwrap();
    let signing = SigningKey::from_bytes(&SEED);
    let mut envelope = SignedCatalogue {
        recipes: vec![RecipeFixture::example()],
        signature: spark_models::catalogue::CatalogueSignature {
            key_id: "catalogue-test".into(),
            algorithm: "ed25519".into(),
            value: String::new(),
        },
    };
    envelope.recipes[0].engine.image = "nvcr.io/nvidia/vllm:latest".into();
    testkit::sign_recipe(&mut envelope.recipes[0], &signing);
    let canonical = envelope.canonical_entries().unwrap();
    envelope.signature.value = testkit::sign_bytes(&canonical, &signing);
    let path = dir.path().join("bad.json");
    std::fs::write(&path, serde_json::to_vec(&envelope).unwrap()).unwrap();
    let root = dir.path().join("root.pub");
    std::fs::write(&root, hex::encode(signing.verifying_key().to_bytes())).unwrap();
    let result = ModelInventory::from_catalogue(Some(&path), Some(&root), None, false);
    assert!(
        result.is_err(),
        "unpinned image recipe must fail verification"
    );
}
