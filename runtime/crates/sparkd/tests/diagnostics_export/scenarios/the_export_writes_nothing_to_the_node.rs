#[tokio::test]
async fn the_export_writes_nothing_to_the_node() {
    let (state, client, directory) = test_state("owner");
    let before = listing(directory.path());
    export(state, &client, &["host-paths", "network-addresses"]).await;
    assert_eq!(
        listing(directory.path()),
        before,
        "the bundle must exist only in the response; a copy left on the node \
         is a second place for it to leak from"
    );
}
