//! Read the system zone database through the daemon's one TZif reader, so an owner's local time survives daylight saving and the footer rule.
use std::path::{Path, PathBuf};

use crate::tzif::Tzif;

/// The zone files DGX OS and the build machines both ship.
const ZONEINFO_ROOT: &str = "/usr/share/zoneinfo";

/// How far either side of a local reading a missing hour can be looked for.
const GAP_SEARCH_SECONDS: i64 = 2 * 86_400;

/// Refuse an unusable zone at configuration time instead of drifting to UTC at three in the morning.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TimezoneError {
    /// The name is not an acceptable IANA zone name.
    Name,
    /// No zone file of that name exists on this machine.
    Missing,
    /// The zone file exists but is not a TZif file this reader understands.
    Malformed,
}

impl TimezoneError {
    pub fn code(&self) -> &'static str {
        match self {
            TimezoneError::Name | TimezoneError::Missing => "AUTOMATION_TIMEZONE_UNKNOWN",
            TimezoneError::Malformed => "AUTOMATION_TIMEZONE_UNREADABLE",
        }
    }
}

/// Transitions for one IANA zone, plus whatever rule its footer carries beyond them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Timezone {
    name: String,
    zone: Tzif,
}

/// Accept `Area/Location`, `Area/Location/Sub` and the bare aliases such as `UTC`, and nothing that could escape the root.
pub fn valid_name(name: &str) -> bool {
    if name.is_empty() || name.len() > 64 || name.starts_with('/') || name.ends_with('/') {
        return false;
    }
    if name.split('/').count() > 3 {
        return false;
    }
    name.split('/').all(|segment| {
        !segment.is_empty()
            && segment != "."
            && segment != ".."
            && segment.len() <= 32
            && segment.starts_with(|c: char| c.is_ascii_alphanumeric())
            && segment
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '+')
    })
}

impl Timezone {
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Load from the machine's zone database.
    pub fn load(name: &str) -> Result<Self, TimezoneError> {
        Self::load_from(Path::new(ZONEINFO_ROOT), name)
    }

    /// Load from an explicit root; tests point this at a fixture directory.
    pub fn load_from(root: &Path, name: &str) -> Result<Self, TimezoneError> {
        if !valid_name(name) {
            return Err(TimezoneError::Name);
        }
        let mut path = PathBuf::from(root);
        for segment in name.split('/') {
            path.push(segment);
        }
        let bytes = std::fs::read(&path).map_err(|_| TimezoneError::Missing)?;
        Self::parse(name, &bytes)
    }

    /// A zone that is always UTC, used when the owner picks no zone at all.
    pub fn utc() -> Self {
        Self {
            name: "UTC".to_owned(),
            zone: Tzif::fixed(0),
        }
    }

    /// The UTC offset in effect at an absolute instant.
    pub fn offset_at(&self, unix_seconds: i64) -> i32 {
        self.zone.offset_at(unix_seconds)
    }

    /// A reading in a spring-forward gap returns the first instant that exists; one in a fall-back overlap returns the earlier of the two, so a daily automation fires once.
    pub fn local_to_unix(&self, local_seconds: i64) -> i64 {
        let mut best: Option<i64> = None;
        for offset in self.zone.distinct_offsets() {
            let candidate = local_seconds - i64::from(offset);
            if self.offset_at(candidate) == offset {
                best = Some(best.map_or(candidate, |current: i64| current.min(candidate)));
            }
        }
        if let Some(found) = best {
            return found;
        }
        // The reading is inside a gap: fire at the transition that removed it.
        let approximate = local_seconds - i64::from(self.offset_at(local_seconds));
        self.zone
            .transitions_between(
                approximate - GAP_SEARCH_SECONDS,
                approximate + GAP_SEARCH_SECONDS,
            )
            .into_iter()
            .find(|instant| {
                let before = self.offset_at(instant - 1);
                let after = self.offset_at(*instant);
                instant + i64::from(before) <= local_seconds
                    && local_seconds < instant + i64::from(after)
            })
            .unwrap_or(approximate)
    }

    fn parse(name: &str, bytes: &[u8]) -> Result<Self, TimezoneError> {
        Ok(Self {
            name: name.to_owned(),
            zone: Tzif::parse(bytes).map_err(|_| TimezoneError::Malformed)?,
        })
    }
}

#[cfg(test)]
#[path = "timezone/tests.rs"]
mod tests;
