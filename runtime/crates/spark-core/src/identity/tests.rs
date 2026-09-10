use super::*;

#[test]
fn generated_fingerprint_is_sha256_of_public_key() {
    let identity = NodeIdentity::generate("test-node");
    let expected = hex::encode(Sha256::digest(
        identity.public.verifying_key().unwrap().to_bytes(),
    ));
    assert_eq!(identity.fingerprint(), expected);
    assert_eq!(identity.public.authority_public_key.len(), 64);
    assert_eq!(identity.fingerprint().len(), 64);
}

#[test]
fn short_node_id_is_first_eight_hex_chars() {
    let id = Uuid::parse_str("7a836150-16e1-46b5-8ac0-32b2a5f2f820").unwrap();
    assert_eq!(short_node_id(id), "7a836150");
}
