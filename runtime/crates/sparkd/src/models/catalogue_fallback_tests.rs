use super::*;

struct Fixture {
    _temp: tempfile::TempDir,
    root_path: std::path::PathBuf,
    bootstrap_path: std::path::PathBuf,
    live_path: std::path::PathBuf,
    bootstrap: Vec<u8>,
}

/// Reproduce packaged bootstrap and trust paths alongside a test-controlled live catalogue.
fn fixture() -> Fixture {
    let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let temp = tempfile::tempdir().unwrap();
    let root_path = temp.path().join("trust/catalogue-root.pub");
    std::fs::create_dir_all(root_path.parent().unwrap()).unwrap();
    std::fs::copy(
        repository.join("packaging/trust/catalogue-root.pub"),
        &root_path,
    )
    .unwrap();
    let bootstrap =
        std::fs::read(repository.join("packaging/catalogue/bootstrap.lab.json")).unwrap();
    let bootstrap_path = temp.path().join("catalog/bootstrap.json");
    std::fs::create_dir_all(bootstrap_path.parent().unwrap()).unwrap();
    std::fs::write(&bootstrap_path, &bootstrap).unwrap();
    let live_path = temp.path().join("live/catalogue.json");
    std::fs::create_dir_all(live_path.parent().unwrap()).unwrap();
    Fixture {
        _temp: temp,
        root_path,
        bootstrap_path,
        live_path,
        bootstrap,
    }
}

fn assert_bootstrap_recipes(inventory: &ModelInventory, bootstrap: &[u8]) {
    let catalogue: serde_json::Value = serde_json::from_slice(bootstrap).unwrap();
    let expected: Vec<&str> = catalogue["recipes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|recipe| recipe["metadata"]["id"].as_str().unwrap())
        .collect();
    assert!(!expected.is_empty());
    let actual: Vec<&str> = inventory.recipes.iter().map(|recipe| recipe.id()).collect();
    assert_eq!(actual, expected);
}

/// Model a live catalogue signed by the retired root that current trust rejects.
fn stale_live_catalogue(bootstrap: &[u8]) -> Vec<u8> {
    let stale = String::from_utf8(bootstrap.to_vec())
        .unwrap()
        .replace("catalogue-2026-b", "catalogue-2026-a");
    assert_ne!(
        stale.as_bytes(),
        bootstrap,
        "the fixture must reference the current key id"
    );
    stale.into_bytes()
}

#[test]
fn stale_live_catalogue_falls_back_to_the_bootstrap_and_promotes_it() {
    let fixture = fixture();
    std::fs::write(&fixture.live_path, stale_live_catalogue(&fixture.bootstrap)).unwrap();

    let inventory = ModelInventory::from_catalogue(
        Some(&fixture.live_path),
        Some(&fixture.root_path),
        Some(&fixture.bootstrap_path),
        false,
    )
    .expect("the packaged bootstrap keeps the daemon serving");

    assert_bootstrap_recipes(&inventory, &fixture.bootstrap);
    assert_eq!(
        std::fs::read(&fixture.live_path).unwrap(),
        fixture.bootstrap,
        "the verified bootstrap replaces the stale live copy"
    );
    let leftovers = std::fs::read_dir(fixture.live_path.parent().unwrap())
        .unwrap()
        .count();
    assert_eq!(leftovers, 1, "promotion leaves no temporary file behind");
}

#[test]
fn stale_live_catalogue_without_a_bootstrap_stays_a_hard_error() {
    let fixture = fixture();
    let stale = stale_live_catalogue(&fixture.bootstrap);
    std::fs::write(&fixture.live_path, &stale).unwrap();
    let missing = fixture.bootstrap_path.with_file_name("absent.json");

    for bootstrap in [None, Some(missing.as_path())] {
        let error = ModelInventory::from_catalogue(
            Some(&fixture.live_path),
            Some(&fixture.root_path),
            bootstrap,
            false,
        )
        .expect_err("no verified catalogue means no start");
        assert!(error.contains("catalogue-2026-a"), "{error}");
    }
    assert_eq!(
        std::fs::read(&fixture.live_path).unwrap(),
        stale,
        "a failed start never rewrites the live catalogue"
    );
}

#[test]
fn unverifiable_bootstrap_reports_both_failures() {
    let fixture = fixture();
    let stale = stale_live_catalogue(&fixture.bootstrap);
    std::fs::write(&fixture.live_path, &stale).unwrap();
    std::fs::write(&fixture.bootstrap_path, &stale).unwrap();

    let error = ModelInventory::from_catalogue(
        Some(&fixture.live_path),
        Some(&fixture.root_path),
        Some(&fixture.bootstrap_path),
        false,
    )
    .expect_err("a stale bootstrap cannot rescue a stale live copy");
    assert!(error.contains("does not verify either"), "{error}");
}

#[test]
fn verifying_live_catalogue_is_served_untouched() {
    let fixture = fixture();
    std::fs::write(&fixture.live_path, &fixture.bootstrap).unwrap();
    std::fs::remove_file(&fixture.bootstrap_path).unwrap();

    let inventory = ModelInventory::from_catalogue(
        Some(&fixture.live_path),
        Some(&fixture.root_path),
        Some(&fixture.bootstrap_path),
        false,
    )
    .unwrap();

    assert_bootstrap_recipes(&inventory, &fixture.bootstrap);
    assert_eq!(
        std::fs::read(&fixture.live_path).unwrap(),
        fixture.bootstrap
    );
}
