fn fresh_nonce() -> String {
    let mut nonce = [0u8; 24];
    rand::rng().fill_bytes(&mut nonce);
    base64url_encode(&nonce)
}
