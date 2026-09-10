use spark_models::recipe::fixture::RecipeFixture;
use sparkd::download_http::{production_coordinator, validated_next_page};

#[test]
fn production_coordinator_rejects_mutable_revisions_before_network_io() {
    let mut recipe = RecipeFixture::example();
    recipe.source.revision = "main".into();

    let coordinator = production_coordinator();
    let error = coordinator
        .resolver
        .resolve(&recipe)
        .expect_err("mutable revision must fail before a request");

    assert!(error.contains("40 lowercase hexadecimal"), "{error}");
}

#[test]
fn pagination_never_moves_provider_credentials_off_the_hugging_face_origin() {
    let current = "https://huggingface.co/api/models/acme/model/tree/0123456789abcdef0123456789abcdef01234567?recursive=true";
    let safe = "<https://huggingface.co/api/models/acme/model/tree/0123456789abcdef0123456789abcdef01234567?recursive=true&cursor=next>; rel=\"next\"";
    let hostile = "<https://attacker.invalid/steal>; rel=\"next\"";

    assert_eq!(
        validated_next_page(current, safe).unwrap().as_deref(),
        Some(
            "https://huggingface.co/api/models/acme/model/tree/0123456789abcdef0123456789abcdef01234567?recursive=true&cursor=next"
        )
    );
    assert!(validated_next_page(current, hostile).is_err());
}

#[test]
#[ignore = "requires internet access"]
fn pinned_public_repository_resolves_and_serves_an_exact_range() {
    let mut recipe = RecipeFixture::example();
    recipe.source.repository = "HuggingFaceTB/SmolLM2-135M-Instruct".into();
    recipe.source.revision = "12fd25f77366fa6b3b4b768ec3050bf629380bac".into();
    let coordinator = production_coordinator();

    let files = coordinator.resolver.resolve(&recipe).unwrap();
    let config = files
        .iter()
        .find(|file| file.relative_path == "config.json")
        .expect("pinned repository contains config.json");
    let first_byte = coordinator
        .source
        .fetch(&recipe, config, Some((0, 1)))
        .unwrap();

    assert_eq!(first_byte.len(), 1);
}
