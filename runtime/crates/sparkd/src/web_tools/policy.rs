//! The owner's standing decision about model internet access, and which surface it reaches.
use super::backend::WebAccessSettings;

/// Longest domain list the owner may store, and the longest entry in one.
pub const MAX_DOMAIN_ENTRIES: usize = 64;
pub const MAX_DOMAIN_LENGTH: usize = 253;

/// What the owner has allowed, set on the Spark and changed from a paired owner device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum WebAccessPolicy {
    /// Nothing on this Spark may reach the internet on the model's behalf.
    #[default]
    Off,
    /// Only scheduled automations may, and only those the owner opted in.
    AutomationsOnly,
    /// Automations and first-party chats may, each still opted in on its own.
    AutomationsAndChats,
}

impl WebAccessPolicy {
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "off" => WebAccessPolicy::Off,
            "automations" => WebAccessPolicy::AutomationsOnly,
            "automations_and_chats" => WebAccessPolicy::AutomationsAndChats,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            WebAccessPolicy::Off => "off",
            WebAccessPolicy::AutomationsOnly => "automations",
            WebAccessPolicy::AutomationsAndChats => "automations_and_chats",
        }
    }
}

/// Who is asking for the web tools. A surface is decided by the route, never by the caller.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Surface {
    /// A scheduled or manually triggered automation run.
    Automation,
    /// A first-party conversation in the owner's own app.
    Chat,
    /// Any third-party client on the OpenAI-compatible gateway.
    Harness,
}

impl Surface {
    pub fn name(self) -> &'static str {
        match self {
            Surface::Automation => "automation",
            Surface::Chat => "chat",
            Surface::Harness => "harness",
        }
    }
}

/// May this surface use the web tools at all? The per-automation and per-chat opt-ins sit on top.
pub fn permits(settings: &WebAccessSettings, surface: Surface) -> Result<(), &'static str> {
    if settings.policy == WebAccessPolicy::Off {
        return Err("WEB_ACCESS_POLICY_OFF");
    }
    match surface {
        Surface::Automation => Ok(()),
        Surface::Chat if settings.policy == WebAccessPolicy::AutomationsAndChats => Ok(()),
        Surface::Chat => Err("WEB_ACCESS_CHATS_NOT_PERMITTED"),
        Surface::Harness
            if settings.policy == WebAccessPolicy::AutomationsAndChats
                && settings.harness_access =>
        {
            Ok(())
        }
        Surface::Harness => Err("WEB_ACCESS_HARNESS_NOT_PERMITTED"),
    }
}

/// The plain-words reason a surface was refused, shown to whoever asked.
pub fn explanation(code: &str) -> &'static str {
    match code {
        "WEB_ACCESS_POLICY_OFF" => {
            "Model internet access is switched off on this Spark. The owner can turn it on in Settings."
        }
        "WEB_ACCESS_CHATS_NOT_PERMITTED" => {
            "This Spark allows internet access for automations only, not for conversations."
        }
        "WEB_ACCESS_HARNESS_NOT_PERMITTED" => {
            "Other apps on this Spark's OpenAI-compatible endpoint are not allowed to use the web tools."
        }
        "WEB_DOMAIN_BLOCKED" => {
            "The owner's site list does not allow that address, so it was not read."
        }
        "WEB_SEARCH_BACKEND_INVALID" => {
            "A search service must be an https address, or this Spark's own search on 127.0.0.1; anything else would send the question out in clear text or off this Spark."
        }
        "WEB_SEARCH_BACKEND_INCOMPLETE" => {
            "That search service still needs its address or the owner's key before it can be asked anything."
        }
        "WEB_DOMAIN_ENTRY_INVALID" => {
            "A site list holds bare domain names, without a scheme, a port or a path."
        }
        "WEB_DOMAIN_LIST_TOO_LONG" => "That site list is longer than this Spark will store.",
        _ => "This Spark did not allow that.",
    }
}

/// Does the owner's allow and deny list permit reading this host?
pub fn domain_permitted(settings: &WebAccessSettings, host: &str) -> bool {
    let host = host.trim().trim_end_matches('.').to_ascii_lowercase();
    if host.is_empty() {
        return false;
    }
    if settings
        .deny_domains
        .iter()
        .any(|entry| covers(entry, &host))
    {
        return false;
    }
    settings.allow_domains.is_empty()
        || settings
            .allow_domains
            .iter()
            .any(|entry| covers(entry, &host))
}

/// A list entry covers the name itself and every name under it, never a name that merely ends the same way.
fn covers(entry: &str, host: &str) -> bool {
    let entry = entry.trim().trim_end_matches('.').to_ascii_lowercase();
    !entry.is_empty() && (host == entry || host.ends_with(&format!(".{entry}")))
}

/// Refuse a stored list that is too long, or an entry that is not a bare domain name.
pub fn validate_domains(entries: &[String]) -> Result<(), &'static str> {
    if entries.len() > MAX_DOMAIN_ENTRIES {
        return Err("WEB_DOMAIN_LIST_TOO_LONG");
    }
    for entry in entries {
        let entry = entry.trim();
        let usable = !entry.is_empty()
            && entry.len() <= MAX_DOMAIN_LENGTH
            && entry.contains('.')
            && !entry.starts_with('.')
            && !entry.ends_with('.')
            && entry.chars().all(|character| {
                character.is_ascii_alphanumeric() || character == '-' || character == '.'
            });
        if !usable {
            return Err("WEB_DOMAIN_ENTRY_INVALID");
        }
    }
    Ok(())
}

#[cfg(test)]
#[path = "policy/tests.rs"]
mod tests;
