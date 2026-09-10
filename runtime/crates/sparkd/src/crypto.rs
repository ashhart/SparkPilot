//! Small cryptographic helpers shared by pairing and request authorisation.

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};

/// Encode signature and nonce bytes as unpadded base64url.
pub fn base64url_encode(data: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(data)
}

pub fn base64url_decode(text: &str) -> Result<Vec<u8>, base64::DecodeError> {
    URL_SAFE_NO_PAD.decode(text)
}

/// Standard base64 (SPKI transport uses `contentEncoding: base64`).
pub fn base64_encode(data: &[u8]) -> String {
    STANDARD.encode(data)
}

pub fn base64_decode(text: &str) -> Result<Vec<u8>, base64::DecodeError> {
    STANDARD.decode(text)
}

pub fn sha256_hex(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

/// Lowercase fingerprint: `sha256:...` over binary bytes (audit/diagnostics).
pub fn sha256_fingerprint(data: &[u8]) -> String {
    format!("sha256:{}", sha256_hex(data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64url_round_trips_without_padding() {
        let data = b"hello world";
        let encoded = base64url_encode(data);
        assert!(!encoded.contains('='));
        assert_eq!(base64url_decode(&encoded).unwrap(), data);
        // RFC 4648 §5 known vector.
        assert_eq!(base64url_encode(b"\xfb\xff"), "-_8");
    }

    #[test]
    fn sha256_matches_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
