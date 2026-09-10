use super::*;
use crate::manifest::{ManifestSignature, strip_nulls};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};

const DOMAIN: &[u8] = b"SPARK-RELEASE-DELEGATION-V2\n";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Delegation {
    pub version: u64,
    pub not_before: String,
    pub not_after: String,
    pub signature: ManifestSignature,
}

fn invalid(reason: &str) -> TrustError {
    TrustError::Delegation(reason.to_owned())
}

impl ReleaseTrustRoot {
    pub(super) fn validate_delegation_shape(&self) -> Result<(), TrustError> {
        if self.schema == TRUST_SCHEMA {
            if !self.root_keys.is_empty()
                || self.delegation.is_some()
                || self.minimum_delegation_version.is_some()
            {
                return Err(invalid("schema 1 cannot contain delegation metadata"));
            }
            return Ok(());
        }
        if self.schema != DELEGATED_TRUST_SCHEMA {
            return Err(TrustError::UnsupportedSchema(self.schema));
        }
        let delegation = self
            .delegation
            .as_ref()
            .ok_or_else(|| invalid("missing certificate"))?;
        let minimum = self
            .minimum_delegation_version
            .ok_or_else(|| invalid("missing minimum version"))?;
        if minimum == 0 || delegation.version < minimum || delegation.version > i64::MAX as u64 {
            return Err(invalid(
                "certificate version is invalid or older than the trusted minimum",
            ));
        }
        if self.root_keys.is_empty() || self.keys.is_empty() {
            return Err(TrustError::Empty);
        }
        let mut seen = std::collections::BTreeSet::new();
        for key in self.root_keys.iter().chain(&self.keys) {
            if !seen.insert(&key.key_id) {
                return Err(TrustError::DuplicateKeyId(key.key_id.clone()));
            }
            key.verifying_key()?;
            key.window()?;
            key.revocation()?;
        }
        for root in &self.root_keys {
            if root.purposes != [DELEGATION_PURPOSE] {
                return Err(invalid("root purpose must be release-delegation only"));
            }
        }
        for key in &self.keys {
            if key.purposes.iter().any(|p| p == DELEGATION_PURPOSE)
                || self
                    .root_keys
                    .iter()
                    .any(|root| root.public_key.eq_ignore_ascii_case(&key.public_key))
                || (key.purposes.iter().any(|p| p == CATALOGUE_PURPOSE)
                    && key
                        .purposes
                        .iter()
                        .any(|p| p == MANIFEST_PURPOSE || p == PACKAGE_PURPOSE))
            {
                return Err(invalid(
                    "offline, catalogue and release authorities must be separate",
                ));
            }
        }
        let root = self
            .root_keys
            .iter()
            .find(|key| key.key_id == delegation.signature.key_id)
            .ok_or_else(|| TrustError::UnknownKeyId(delegation.signature.key_id.clone()))?;
        let before = OffsetDateTime::parse(&delegation.not_before, &Rfc3339)
            .map_err(|_| invalid("invalid not_before"))?;
        let after = OffsetDateTime::parse(&delegation.not_after, &Rfc3339)
            .map_err(|_| invalid("invalid not_after"))?;
        let (root_before, root_after) = root.window()?;
        if before >= after || before < root_before || after > root_after {
            return Err(invalid(
                "certificate window exceeds the offline root window",
            ));
        }
        for key in &self.keys {
            let (key_before, key_after) = key.window()?;
            if key_before < before
                || key_after > after
                || key
                    .channels
                    .iter()
                    .any(|channel| !root.channels.contains(channel))
            {
                return Err(invalid(
                    "online key exceeds delegated window or channel scope",
                ));
            }
        }
        if delegation.signature.algorithm != SIGNATURE_ALGORITHM {
            return Err(invalid("unsupported certificate signature algorithm"));
        }
        let bytes: [u8; 64] = URL_SAFE_NO_PAD
            .decode(&delegation.signature.value)
            .map_err(|_| invalid("malformed certificate signature"))?
            .try_into()
            .map_err(|_| invalid("malformed certificate signature"))?;
        let mut payload = serde_json::json!({
            "schema": DELEGATED_TRUST_SCHEMA, "keys": self.keys, "version": delegation.version,
            "not_before": delegation.not_before, "not_after": delegation.not_after,
        });
        strip_nulls(&mut payload);
        let mut canonical = DOMAIN.to_vec();
        canonical.extend(serde_json::to_vec(&payload).map_err(|e| invalid(&e.to_string()))?);
        root.verifying_key()?
            .verify_strict(&canonical, &Signature::from_bytes(&bytes))
            .map_err(|_| TrustError::SignatureInvalid(root.key_id.clone()))
    }

    pub(super) fn authorize_channel(
        &self,
        at: OffsetDateTime,
        channel: &str,
    ) -> Result<(), TrustError> {
        self.validate_delegation_shape()?;
        if self.schema == TRUST_SCHEMA {
            if !DIRECT_TRUST_CHANNELS.contains(&channel) {
                return Err(TrustError::DelegationRequired(channel.to_owned()));
            }
            return Ok(());
        }
        let delegation = self
            .delegation
            .as_ref()
            .ok_or_else(|| invalid("missing certificate"))?;
        let root = self
            .root_keys
            .iter()
            .find(|key| key.key_id == delegation.signature.key_id)
            .ok_or_else(|| invalid("missing offline root"))?;
        root.assert_usable(
            at,
            channel,
            DELEGATION_PURPOSE,
            "delegate online release keys",
        )?;
        let before = OffsetDateTime::parse(&delegation.not_before, &Rfc3339)
            .map_err(|_| invalid("invalid not_before"))?;
        let after = OffsetDateTime::parse(&delegation.not_after, &Rfc3339)
            .map_err(|_| invalid("invalid not_after"))?;
        if at < before || at >= after {
            return Err(invalid("certificate is outside its validity window"));
        }
        Ok(())
    }
}
