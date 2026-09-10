//! The POSIX TZ string a version-2 TZif file carries in its footer: the rule that governs every instant after the last recorded transition.

/// Julian day number of 1970-01-01, so a civil date becomes a Unix day.
const UNIX_EPOCH_JULIAN_DAY: i32 = 2_440_588;

/// POSIX leaves the transition time unstated at two in the morning, local.
const DEFAULT_TRANSITION_SECONDS: i32 = 2 * 3_600;

/// Which local day of a year a seasonal change falls on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Anniversary {
    /// `Jn`: the n-th day of the year with 29 February never counted.
    JulianNoLeap(u16),
    /// `n`: the n-th day of the year counting from zero, 29 February included.
    Ordinal(u16),
    /// `Mm.w.d`: weekday `d` in week `w` of month `m`, week 5 meaning the last one.
    WeekdayOfMonth { month: u8, week: u8, weekday: u8 },
}

/// One seasonal change: which day, and how far into that local day.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Change {
    day: Anniversary,
    seconds: i32,
}

/// The daylight half of a rule, present only when the zone still changes its clocks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Daylight {
    offset: i32,
    start: Change,
    end: Change,
}

/// A parsed footer rule, in seconds east of UTC.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PosixTz {
    standard: i32,
    daylight: Option<Daylight>,
}

impl PosixTz {
    /// Parse a footer; an unusable or unsupported form yields nothing so the caller keeps the transition table.
    pub fn parse(text: &str) -> Option<Self> {
        let mut cursor = Cursor::new(text.trim());
        cursor.name()?;
        let standard = cursor.offset(24)?;
        if cursor.done() {
            return Some(Self {
                standard,
                daylight: None,
            });
        }
        cursor.name()?;
        let daylight_offset = if cursor.peek().is_some_and(|byte| byte != b',') {
            cursor.offset(24)?
        } else {
            standard + 3_600
        };
        // Without an explicit pair of rules the footer means the caller's own defaults; keep the table instead of guessing.
        cursor.expect(b',')?;
        let start = cursor.change()?;
        cursor.expect(b',')?;
        let end = cursor.change()?;
        if !cursor.done() {
            return None;
        }
        Some(Self {
            standard,
            daylight: Some(Daylight {
                offset: daylight_offset,
                start,
                end,
            }),
        })
    }

    pub fn offset_at(&self, unix: i64) -> i32 {
        match self.daylight {
            Some(daylight) if self.in_daylight(unix, daylight) => daylight.offset,
            _ => self.standard,
        }
    }

    pub fn is_daylight_saving_at(&self, unix: i64) -> bool {
        self.daylight
            .is_some_and(|daylight| self.in_daylight(unix, daylight))
    }

    /// Every offset the rule can produce, for a local reading that must be tried against each.
    pub fn offsets(&self) -> Vec<i32> {
        match self.daylight {
            Some(daylight) => vec![self.standard, daylight.offset],
            None => vec![self.standard],
        }
    }

    /// The two instants at which this rule changes the clock in one civil year, in order.
    pub fn transitions_in_year(&self, year: i32) -> Vec<i64> {
        let Some(daylight) = self.daylight else {
            return Vec::new();
        };
        let mut instants = [
            instant(&daylight.start, year, self.standard),
            instant(&daylight.end, year, daylight.offset),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
        instants.sort_unstable();
        instants
    }

    fn in_daylight(&self, unix: i64, daylight: Daylight) -> bool {
        let Some(year) = year_of(unix.saturating_add(i64::from(self.standard))) else {
            return false;
        };
        let (Some(start), Some(end)) = (
            instant(&daylight.start, year, self.standard),
            instant(&daylight.end, year, daylight.offset),
        ) else {
            return false;
        };
        if start <= end {
            unix >= start && unix < end
        } else {
            // Southern hemisphere: daylight saving spans the new year.
            unix >= start || unix < end
        }
    }
}

fn year_of(unix: i64) -> Option<i32> {
    time::OffsetDateTime::from_unix_timestamp(unix)
        .ok()
        .map(|moment| moment.year())
}

fn is_leap(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

/// The UTC instant of one seasonal change in one year, given the offset in force just before it.
fn instant(change: &Change, year: i32, offset_before: i32) -> Option<i64> {
    let ordinal = match change.day {
        Anniversary::JulianNoLeap(day) => {
            let leap_shift = u16::from(day >= 60 && is_leap(year));
            day.checked_add(leap_shift)?
        }
        Anniversary::Ordinal(day) => day.checked_add(1)?,
        Anniversary::WeekdayOfMonth {
            month,
            week,
            weekday,
        } => month_week_day_ordinal(year, month, week, weekday)?,
    };
    let date = time::Date::from_ordinal_date(year, ordinal).ok()?;
    let day = i64::from(date.to_julian_day() - UNIX_EPOCH_JULIAN_DAY);
    Some(day * 86_400 + i64::from(change.seconds) - i64::from(offset_before))
}

fn month_week_day_ordinal(year: i32, month: u8, week: u8, weekday: u8) -> Option<u16> {
    let month = time::Month::try_from(month).ok()?;
    let first = time::Date::from_calendar_date(year, month, 1).ok()?;
    let first_weekday = u32::from(first.weekday().number_days_from_sunday());
    let shift = (u32::from(weekday) + 7 - first_weekday) % 7;
    let length = u32::from(time::util::days_in_month(month, year));
    let mut day = shift + 1 + u32::from(week - 1) * 7;
    while day > length {
        day -= 7;
    }
    Some(first.ordinal() + u16::try_from(day - 1).ok()?)
}

/// A byte cursor over the footer text; every reader refuses rather than guessing.
struct Cursor<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Cursor<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            bytes: text.as_bytes(),
            at: 0,
        }
    }

    fn done(&self) -> bool {
        self.at >= self.bytes.len()
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn expect(&mut self, byte: u8) -> Option<()> {
        (self.peek()? == byte).then(|| self.at += 1)
    }

    /// A zone abbreviation: three or more letters, or any `<...>` quoted form.
    fn name(&mut self) -> Option<()> {
        if self.peek()? == b'<' {
            self.at += 1;
            let start = self.at;
            while self
                .peek()
                .is_some_and(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'-'))
            {
                self.at += 1;
            }
            let length = self.at - start;
            self.expect(b'>')?;
            return (length >= 3).then_some(());
        }
        let start = self.at;
        while self.peek().is_some_and(|byte| byte.is_ascii_alphabetic()) {
            self.at += 1;
        }
        (self.at - start >= 3).then_some(())
    }

    fn digits(&mut self, most: usize) -> Option<u32> {
        let start = self.at;
        while self.at - start < most && self.peek().is_some_and(|byte| byte.is_ascii_digit()) {
            self.at += 1;
        }
        std::str::from_utf8(&self.bytes[start..self.at])
            .ok()?
            .parse()
            .ok()
    }

    /// `[+|-]hh[:mm[:ss]]`, POSIX-signed (west positive), returned as seconds east of UTC.
    fn offset(&mut self, most_hours: u32) -> Option<i32> {
        let negative = match self.peek() {
            Some(b'-') => {
                self.at += 1;
                true
            }
            Some(b'+') => {
                self.at += 1;
                false
            }
            _ => false,
        };
        let hours = self.digits(3)?;
        if hours > most_hours {
            return None;
        }
        let mut seconds = hours * 3_600;
        if self.peek() == Some(b':') {
            self.at += 1;
            let minutes = self.digits(2)?;
            if minutes > 59 {
                return None;
            }
            seconds += minutes * 60;
            if self.peek() == Some(b':') {
                self.at += 1;
                let value = self.digits(2)?;
                if value > 59 {
                    return None;
                }
                seconds += value;
            }
        }
        let seconds = i32::try_from(seconds).ok()?;
        // POSIX writes offsets west-positive; the daemon stores them east-positive.
        Some(if negative { seconds } else { -seconds })
    }

    fn change(&mut self) -> Option<Change> {
        let day = match self.peek()? {
            b'J' => {
                self.at += 1;
                let day = self.digits(3)?;
                (1..=365).contains(&day).then_some(())?;
                Anniversary::JulianNoLeap(u16::try_from(day).ok()?)
            }
            b'M' => {
                self.at += 1;
                let month = self.digits(2)?;
                self.expect(b'.')?;
                let week = self.digits(1)?;
                self.expect(b'.')?;
                let weekday = self.digits(1)?;
                ((1..=12).contains(&month) && (1..=5).contains(&week) && weekday <= 6)
                    .then_some(())?;
                Anniversary::WeekdayOfMonth {
                    month: u8::try_from(month).ok()?,
                    week: u8::try_from(week).ok()?,
                    weekday: u8::try_from(weekday).ok()?,
                }
            }
            _ => {
                let day = self.digits(3)?;
                (day <= 365).then_some(())?;
                Anniversary::Ordinal(u16::try_from(day).ok()?)
            }
        };
        let seconds = if self.peek() == Some(b'/') {
            self.at += 1;
            // The time of day is signed and may leave the day: negate the offset reader's POSIX sign.
            -self.offset(167)?
        } else {
            DEFAULT_TRANSITION_SECONDS
        };
        Some(Change { day, seconds })
    }
}
