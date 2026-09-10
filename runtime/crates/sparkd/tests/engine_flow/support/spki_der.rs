fn spki_der(key: &p256::ecdsa::SigningKey) -> Vec<u8> {
    key.verifying_key()
        .to_public_key_der()
        .expect("spki der")
        .as_bytes()
        .to_vec()
}
