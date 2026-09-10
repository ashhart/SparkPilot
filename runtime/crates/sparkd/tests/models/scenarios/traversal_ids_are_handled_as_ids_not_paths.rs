#[tokio::test]
async fn traversal_ids_are_handled_as_ids_not_paths() {
    let peer = full_peer(false);
    for id in ["..%2F..%2Fetc%2Fpasswd", "%2Fetc%2Fpasswd", "a%2Fb%2Fc"] {
        let (status, _) = get(&peer, &format!("/api/v1/models/{id}")).await;
        assert_eq!(
            status,
            StatusCode::NOT_FOUND,
            "traversal id {id} never touches the filesystem"
        );
    }
}
