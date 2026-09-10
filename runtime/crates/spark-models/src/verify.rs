//! Ed25519 verification of model recipes and catalogue snapshots (§29.1).

use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use thiserror::Error;

use crate::recipe::ModelRecipe;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum VerifyError {
    #[error("signature algorithm must be ed25519, got {0}")]
    UnsupportedAlgorithm(String),
    #[error("key id {0} is not accepted by this trust root")]
    UnknownKeyId(String),
    #[error("signature is not valid base64url")]
    BadEncoding,
    #[error("signature does not verify")]
    Invalid,
    #[error("recipe failed validation: {0}")]
    InvalidRecipe(String),
    #[error("JSON error: {0}")]
    Json(String),
}

/// Use the current catalogue key-id mapping; broader rotation policy belongs to release trust tooling.
pub struct CatalogueRoot {
    /// Accept these audited key ids, which currently share one embedded verifying key.
    pub key_ids: Vec<String>,
    pub verifying_key: VerifyingKey,
}

impl CatalogueRoot {
    pub fn verify_recipe(&self, recipe: &ModelRecipe) -> Result<(), VerifyError> {
        if !self.key_ids.contains(&recipe.signature.key_id) {
            return Err(VerifyError::UnknownKeyId(recipe.signature.key_id.clone()));
        }
        if recipe.signature.algorithm != "ed25519" {
            return Err(VerifyError::UnsupportedAlgorithm(
                recipe.signature.algorithm.clone(),
            ));
        }
        let sig = decode_signature(&recipe.signature.value)?;
        let canonical = recipe
            .canonical_without_signature()
            .map_err(|e| VerifyError::Json(e.to_string()))?;
        self.verifying_key
            .verify(&canonical, &sig)
            .map_err(|_| VerifyError::Invalid)
    }

    pub fn verify_bytes(
        &self,
        canonical: &[u8],
        algorithm: &str,
        value: &str,
    ) -> Result<(), VerifyError> {
        if algorithm != "ed25519" {
            return Err(VerifyError::UnsupportedAlgorithm(algorithm.into()));
        }
        let sig = decode_signature(value)?;
        self.verifying_key
            .verify(canonical, &sig)
            .map_err(|_| VerifyError::Invalid)
    }

    #[cfg(any(test, feature = "testkit"))]
    pub fn from_seed(seed: &[u8; 32]) -> Self {
        use ed25519_dalek::SigningKey;
        let signing = SigningKey::from_bytes(seed);
        Self {
            key_ids: vec!["catalogue-test".into()],
            verifying_key: VerifyingKey::from(&signing),
        }
    }
}

fn decode_signature(value: &str) -> Result<Signature, VerifyError> {
    use base64::Engine;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let bytes = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| VerifyError::BadEncoding)?;
    let bytes: [u8; 64] = bytes.try_into().map_err(|_| VerifyError::BadEncoding)?;
    Ok(Signature::from_bytes(&bytes))
}

/// Test-only signer so catalogues can be produced for verification tests.
#[cfg(any(test, feature = "testkit"))]
pub mod testkit {
    use ed25519_dalek::{Signer, SigningKey};
    use serde_json::Value;

    use crate::recipe::ModelRecipe;

    /// Sign a recipe's canonical bytes and stamp the signature into it.
    pub fn sign_recipe(recipe: &mut ModelRecipe, signing: &SigningKey) {
        recipe.signature.algorithm = "ed25519".into();
        recipe.signature.key_id = "catalogue-test".into();
        let canonical = recipe.canonical_without_signature().expect("canonical");
        let signature: ed25519_dalek::Signature = signing.sign(&canonical);
        use base64::Engine;
        use base64::engine::general_purpose::URL_SAFE_NO_PAD;
        recipe.signature.value = URL_SAFE_NO_PAD.encode(signature.to_bytes());
    }

    /// Deterministic canonical JSON for a top-level catalogue envelope.
    pub fn canonical_catalogue(entries: &[Value]) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({ "recipes": entries })).expect("catalogue json")
    }

    pub fn sign_bytes(canonical: &[u8], signing: &SigningKey) -> String {
        let signature: ed25519_dalek::Signature = signing.sign(canonical);
        use base64::Engine;
        use base64::engine::general_purpose::URL_SAFE_NO_PAD;
        URL_SAFE_NO_PAD.encode(signature.to_bytes())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recipe::ModelRecipe;

    fn fixture() -> ModelRecipe {
        // Reuse a minimal structurally-valid recipe.
        crate::recipe::fixture::RecipeFixture::example()
    }

    #[test]
    fn valid_signature_verifies() {
        let mut recipe = fixture();
        let seed = [7u8; 32];
        use ed25519_dalek::SigningKey;
        let signing = SigningKey::from_bytes(&seed);
        testkit::sign_recipe(&mut recipe, &signing);
        let root = CatalogueRoot::from_seed(&seed);
        assert!(root.verify_recipe(&recipe).is_ok());
    }

    #[test]
    fn wrong_key_signature_is_rejected() {
        let mut recipe = fixture();
        use ed25519_dalek::SigningKey;
        let (good_seed, bad_seed) = ([1u8; 32], [2u8; 32]);
        testkit::sign_recipe(&mut recipe, &SigningKey::from_bytes(&good_seed));
        let root = CatalogueRoot::from_seed(&bad_seed);
        assert_eq!(root.verify_recipe(&recipe), Err(VerifyError::Invalid));
    }

    #[test]
    fn unknown_key_id_is_rejected() {
        let mut recipe = fixture();
        let seed = [3u8; 32];
        use ed25519_dalek::SigningKey;
        testkit::sign_recipe(&mut recipe, &SigningKey::from_bytes(&seed));
        recipe.signature.key_id = "not-in-root".into();
        let root = CatalogueRoot::from_seed(&seed);
        assert!(matches!(
            root.verify_recipe(&recipe),
            Err(VerifyError::UnknownKeyId(_))
        ));
    }

    #[test]
    fn tampered_recipe_is_rejected() {
        let mut recipe = fixture();
        let seed = [4u8; 32];
        use ed25519_dalek::SigningKey;
        testkit::sign_recipe(&mut recipe, &SigningKey::from_bytes(&seed));
        recipe.memory.expected_weight_bytes += 1;
        let root = CatalogueRoot::from_seed(&seed);
        assert_eq!(root.verify_recipe(&recipe), Err(VerifyError::Invalid));
    }
}
