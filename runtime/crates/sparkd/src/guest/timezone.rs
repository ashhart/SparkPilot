//! Read the installed TZif database so guest hours follow the owner's real local clock, daylight saving and the footer rule included.

use std::path::{Path, PathBuf};

use crate::tzif::{MAX_ZONE_FILE_BYTES, Tzif};

/// Where Linux and macOS both keep the compiled zone files.
pub const ZONEINFO_ROOT: &str = "/usr/share/zoneinfo";

#[derive(Debug, thiserror::Error, Clone, PartialEq, Eq)]
pub enum TimeZoneError {
    #[error("time zone name is not a database entry")]
    UnsafeName,
    #[error("time zone {0} is not installed on this node")]
    NotInstalled(String),
    #[error("time zone file is malformed")]
    Malformed,
}

/// The owner's local wall clock at one instant, in the fields a schedule needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalTime {
    pub year: i32,
    pub month: u8,
    pub day: u8,
    /// Monday is 0, matching the policy's weekday index.
    pub weekday: u8,
    pub minute_of_day: u16,
    pub second_of_minute: u8,
    pub offset_seconds: i32,
    pub unix: i64,
}

impl LocalTime {
    /// Seconds elapsed since the local day began, used to find the day boundary.
    pub fn seconds_of_day(&self) -> i64 {
        i64::from(self.minute_of_day) * 60 + i64::from(self.second_of_minute)
    }

    /// The local calendar date as the store keys daily counters.
    pub fn date(&self) -> String {
        format!("{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
}

/// One zone, resolved from the installed database through the shared TZif reader.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TimeZone {
    name: String,
    zone: Tzif,
}

impl TimeZone {
    /// Resolve a named zone from the installed database, refusing anything that is not a plain entry name.
    pub fn load(name: &str) -> Result<TimeZone, TimeZoneError> {
        Self::load_from(Path::new(ZONEINFO_ROOT), name)
    }

    pub fn load_from(root: &Path, name: &str) -> Result<TimeZone, TimeZoneError> {
        let path = safe_zone_path(root, name)?;
        let metadata =
            std::fs::metadata(&path).map_err(|_| TimeZoneError::NotInstalled(name.to_owned()))?;
        if !metadata.is_file() || metadata.len() > MAX_ZONE_FILE_BYTES {
            return Err(TimeZoneError::NotInstalled(name.to_owned()));
        }
        let bytes =
            std::fs::read(&path).map_err(|_| TimeZoneError::NotInstalled(name.to_owned()))?;
        let mut zone = Self::parse(&bytes)?;
        zone.name = name.to_owned();
        Ok(zone)
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// Parse a TZif body through the one reader the daemon shares with the automations schedule.
    pub fn parse(bytes: &[u8]) -> Result<TimeZone, TimeZoneError> {
        Ok(TimeZone {
            name: String::new(),
            zone: Tzif::parse(bytes).map_err(|_| TimeZoneError::Malformed)?,
        })
    }

    /// The UTC offset in force at a UTC instant.
    pub fn offset_seconds_at(&self, unix: i64) -> i32 {
        self.zone.offset_at(unix)
    }

    /// Whether daylight saving is in force at a UTC instant.
    pub fn is_daylight_saving_at(&self, unix: i64) -> bool {
        self.zone.is_daylight_saving_at(unix)
    }

    /// The owner's local wall clock at a UTC instant.
    pub fn local_at(&self, unix: i64) -> Result<LocalTime, TimeZoneError> {
        let offset_seconds = self.offset_seconds_at(unix);
        let shifted = unix
            .checked_add(i64::from(offset_seconds))
            .ok_or(TimeZoneError::Malformed)?;
        let wall = time::OffsetDateTime::from_unix_timestamp(shifted)
            .map_err(|_| TimeZoneError::Malformed)?;
        Ok(LocalTime {
            year: wall.year(),
            month: u8::from(wall.month()),
            day: wall.day(),
            weekday: wall.weekday().number_days_from_monday(),
            minute_of_day: u16::from(wall.hour()) * 60 + u16::from(wall.minute()),
            second_of_minute: wall.second(),
            offset_seconds,
            unix,
        })
    }

    /// The UTC instant at which the given local day began.
    pub fn local_day_start(&self, local: &LocalTime) -> i64 {
        local.unix - local.seconds_of_day()
    }

    /// The UTC instant at which the local day containing `unix` gives way to the next one.
    pub fn next_local_midnight(&self, unix: i64) -> Result<i64, TimeZoneError> {
        let local = self.local_at(unix)?;
        // Probe two hours past the naive boundary so any daylight-saving shift still lands inside the next local day.
        let probe = self.local_day_start(&local) + 86_400 + 7_200;
        let next = self.local_at(probe)?;
        Ok(self.local_day_start(&next))
    }
}

/// Accept only plain database entry names so an owner-supplied zone cannot read another file.
fn safe_zone_path(root: &Path, name: &str) -> Result<PathBuf, TimeZoneError> {
    if name.is_empty() || name.len() > 64 || name.starts_with('/') {
        return Err(TimeZoneError::UnsafeName);
    }
    let mut path = root.to_path_buf();
    let mut segments = 0;
    for segment in name.split('/') {
        if segment.is_empty() || segment == "." || segment == ".." {
            return Err(TimeZoneError::UnsafeName);
        }
        if !segment
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'+'))
        {
            return Err(TimeZoneError::UnsafeName);
        }
        path.push(segment);
        segments += 1;
    }
    if segments > 3 {
        return Err(TimeZoneError::UnsafeName);
    }
    Ok(path)
}

#[cfg(test)]
#[path = "timezone_tests.rs"]
mod tests;
