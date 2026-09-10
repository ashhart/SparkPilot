use super::*;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OverlayPreferences {
    pub provider: String,
    pub enabled: bool,
    pub accept_dns: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OverlayPreferenceChange {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accept_dns: Option<bool>,
}

impl OverlayPreferenceChange {
    pub fn is_valid(self) -> bool {
        self.enabled.is_some() != self.accept_dns.is_some()
    }
}

impl PrivdOverlayProvisioner {
    pub(super) fn preferences_call(
        &self,
        operation: spark_privd::protocol::PrivilegedOperation,
        deadline: Duration,
    ) -> Result<OverlayPreferences, String> {
        let response = self
            .client
            .call_bounded(operation, deadline)
            .map_err(|_| "Tailscale preferences could not be verified".to_owned())?;
        if !response.accepted {
            return Err("Tailscale could not complete the preference request".into());
        }
        let preferences: OverlayPreferences = serde_json::from_value(response.details)
            .map_err(|_| "Tailscale returned unreadable public preferences".to_owned())?;
        if preferences.provider != "tailscale" {
            return Err("Tailscale preferences named an unknown provider".into());
        }
        Ok(preferences)
    }
}
