//! Parse the restricted cron dialect the app composes and answer when a slot next falls.
use super::timezone::Timezone;
use time::{Date, Month, Weekday};

/// Stop the calendar walk rather than hunting forever for a date that never comes.
const SEARCH_DAYS: u16 = 400;

/// One code for every shape the parser will not honour, so the app has one branch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScheduleError;

impl ScheduleError {
    pub fn code(&self) -> &'static str {
        "AUTOMATION_SCHEDULE_INVALID"
    }
}

/// Which minutes, hours, days, months and weekdays a stored expression selects.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Schedule {
    expression: String,
    minutes: Vec<u32>,
    hours: Vec<u32>,
    days: Vec<u32>,
    months: Vec<u32>,
    weekdays: Vec<u32>,
    /// Cron treats a restricted day-of-month and day-of-week as alternatives, not as an intersection.
    day_is_either: bool,
}

impl Schedule {
    /// Five fields, each `*`, a number, a comma list, an inclusive range, or any of those with `/N`.
    pub fn parse(expression: &str) -> Result<Self, ScheduleError> {
        if expression.len() > 120 {
            return Err(ScheduleError);
        }
        let fields: Vec<&str> = expression.split_whitespace().collect();
        if fields.len() != 5 {
            return Err(ScheduleError);
        }
        let minutes = field(fields[0], 0, 59)?;
        let hours = field(fields[1], 0, 23)?;
        let days = field(fields[2], 1, 31)?;
        let months = field(fields[3], 1, 12)?;
        let weekdays = field(fields[4], 0, 6)?;
        let day_is_either = fields[2] != "*" && fields[4] != "*";
        Ok(Self {
            expression: fields.join(" "),
            minutes,
            hours,
            days,
            months,
            weekdays,
            day_is_either,
        })
    }

    /// The canonical text stored with the automation.
    pub fn expression(&self) -> &str {
        &self.expression
    }

    pub fn daily(hour: u32, minute: u32) -> Self {
        Self::parse(&format!("{minute} {hour} * * *")).expect("a preset is always valid")
    }

    pub fn weekdays(hour: u32, minute: u32) -> Self {
        Self::parse(&format!("{minute} {hour} * * 1-5")).expect("a preset is always valid")
    }

    pub fn every_n_hours(every: u32, minute: u32) -> Self {
        Self::parse(&format!("{minute} */{every} * * *")).expect("a preset is always valid")
    }

    pub fn weekly(weekday: u32, hour: u32, minute: u32) -> Self {
        Self::parse(&format!("{minute} {hour} * * {weekday}")).expect("a preset is always valid")
    }

    /// The first slot strictly after `after`, read in the owner's zone.
    pub fn next_after(&self, after: i64, zone: &Timezone) -> Option<i64> {
        let local_now = after + i64::from(zone.offset_at(after));
        let mut date = local_date(local_now)?;
        let midnight = local_now.div_euclid(86_400) * 86_400;
        for day in 0..SEARCH_DAYS {
            if self.day_matches(date) {
                let day_start = midnight + i64::from(day) * 86_400;
                for hour in &self.hours {
                    for minute in &self.minutes {
                        let reading =
                            day_start + i64::from(*hour) * 3_600 + i64::from(*minute) * 60;
                        let instant = zone.local_to_unix(reading);
                        if instant > after {
                            return Some(instant);
                        }
                    }
                }
            }
            date = date.next_day()?;
        }
        None
    }

    fn day_matches(&self, date: Date) -> bool {
        if !self.months.contains(&u32::from(u8::from(date.month()))) {
            return false;
        }
        let day = u32::from(date.day());
        let weekday = weekday_number(date.weekday());
        if self.day_is_either {
            return self.days.contains(&day) || self.weekdays.contains(&weekday);
        }
        self.days.contains(&day) && self.weekdays.contains(&weekday)
    }
}

/// Sunday is zero, matching cron and the app's day picker.
fn weekday_number(weekday: Weekday) -> u32 {
    match weekday {
        Weekday::Sunday => 0,
        Weekday::Monday => 1,
        Weekday::Tuesday => 2,
        Weekday::Wednesday => 3,
        Weekday::Thursday => 4,
        Weekday::Friday => 5,
        Weekday::Saturday => 6,
    }
}

fn local_date(local_seconds: i64) -> Option<Date> {
    let days = local_seconds.div_euclid(86_400);
    let epoch = Date::from_calendar_date(1970, Month::January, 1).ok()?;
    epoch.checked_add(time::Duration::days(days))
}

/// Expand one comma-separated field into the sorted values it selects.
fn field(text: &str, low: u32, high: u32) -> Result<Vec<u32>, ScheduleError> {
    if text.is_empty() {
        return Err(ScheduleError);
    }
    let mut values = Vec::new();
    for part in text.split(',') {
        for value in part_values(part, low, high)? {
            if !values.contains(&value) {
                values.push(value);
            }
        }
    }
    if values.is_empty() {
        return Err(ScheduleError);
    }
    values.sort_unstable();
    Ok(values)
}

fn part_values(part: &str, low: u32, high: u32) -> Result<Vec<u32>, ScheduleError> {
    let (range, step) = match part.split_once('/') {
        Some((range, step)) => {
            let step: u32 = step.parse().map_err(|_| ScheduleError)?;
            if step == 0 || step > high.saturating_sub(low) + 1 {
                return Err(ScheduleError);
            }
            (range, step)
        }
        None => (part, 1),
    };
    let (first, last) = if range == "*" {
        (low, high)
    } else if let Some((start, end)) = range.split_once('-') {
        let start: u32 = start.parse().map_err(|_| ScheduleError)?;
        let end: u32 = end.parse().map_err(|_| ScheduleError)?;
        if start > end {
            return Err(ScheduleError);
        }
        (start, end)
    } else {
        let single: u32 = range.parse().map_err(|_| ScheduleError)?;
        if step != 1 {
            return Err(ScheduleError);
        }
        (single, single)
    };
    if first < low || last > high {
        return Err(ScheduleError);
    }
    Ok((first..=last).step_by(step as usize).collect())
}

#[cfg(test)]
#[path = "schedule/tests.rs"]
mod tests;
