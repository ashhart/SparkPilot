use super::*;

pub(super) const MAX_P256_SPKI_BASE64_BYTES: usize = 512;

pub(super) const MAX_P256_SPKI_DER_BYTES: usize = 256;

pub(super) fn base64_decode_spki(spki: &str) -> Result<Vec<u8>, PairingError> {
    if spki.len() > MAX_P256_SPKI_BASE64_BYTES {
        return Err(PairingError::BadPublicKey("spki is too large".into()));
    }
    let der = crate::crypto::base64_decode(spki)
        .map_err(|_| PairingError::BadPublicKey("spki is not valid base64".into()))?;
    if der.len() > MAX_P256_SPKI_DER_BYTES {
        return Err(PairingError::BadPublicKey("spki is too large".into()));
    }
    Ok(der)
}

pub(crate) struct CanonicalP256Key {
    pub(crate) verifying_key: P256Verify,
    pub(crate) canonical_point: Vec<u8>,
    pub(crate) canonical_spki: Vec<u8>,
    pub(crate) fingerprint: String,
}

pub(crate) fn canonical_p256_key(spki: &str) -> Result<CanonicalP256Key, PairingError> {
    let der = base64_decode_spki(spki)?;
    canonical_p256_key_der(&der)
}

pub(crate) fn canonical_p256_key_der(der: &[u8]) -> Result<CanonicalP256Key, PairingError> {
    if der.len() > MAX_P256_SPKI_DER_BYTES {
        return Err(PairingError::BadPublicKey("spki is too large".into()));
    }
    let verifying_key = P256Verify::from_public_key_der(der)
        .map_err(|error| PairingError::BadPublicKey(error.to_string()))?;
    let canonical_point = verifying_key.to_encoded_point(false).as_bytes().to_vec();
    let canonical_spki = verifying_key
        .to_public_key_der()
        .map_err(|error| PairingError::BadPublicKey(error.to_string()))?
        .as_bytes()
        .to_vec();
    let fingerprint = sha256_hex(&canonical_point);
    Ok(CanonicalP256Key {
        verifying_key,
        canonical_point,
        canonical_spki,
        fingerprint,
    })
}
