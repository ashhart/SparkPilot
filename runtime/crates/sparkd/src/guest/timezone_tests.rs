use super::*;

/// Build a TZif version-1 body so schedule tests do not depend on the host's installed database.
struct TzifBuilder {
    transitions: Vec<(i64, u8)>,
    types: Vec<(i32, bool)>,
}

impl TzifBuilder {
    fn new() -> Self {
        Self {
            transitions: Vec::new(),
            types: Vec::new(),
        }
    }

    fn with_type(mut self, offset_seconds: i32, is_dst: bool) -> Self {
        self.types.push((offset_seconds, is_dst));
        self
    }

    fn at(mut self, unix: i64, type_index: u8) -> Self {
        self.transitions.push((unix, type_index));
        self
    }

    fn build(&self) -> Vec<u8> {
        self.body(0, false)
    }

    /// A version-2 body whose footer carries the rule for everything after the table.
    fn build_slim(&self, rule: &str) -> Vec<u8> {
        let mut bytes = self.body(b'2', false);
        bytes.extend(self.body(b'2', true));
        bytes.push(b'\n');
        bytes.extend_from_slice(rule.as_bytes());
        bytes.push(b'\n');
        bytes
    }

    fn body(&self, version: u8, wide: bool) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"TZif");
        bytes.push(version);
        bytes.extend_from_slice(&[0u8; 15]);
        bytes.extend_from_slice(&0u32.to_be_bytes());
        bytes.extend_from_slice(&0u32.to_be_bytes());
        bytes.extend_from_slice(&0u32.to_be_bytes());
        bytes.extend_from_slice(&(self.transitions.len() as u32).to_be_bytes());
        bytes.extend_from_slice(&(self.types.len() as u32).to_be_bytes());
        bytes.extend_from_slice(&(self.types.len() as u32).to_be_bytes());
        for (unix, _) in &self.transitions {
            if wide {
                bytes.extend_from_slice(&unix.to_be_bytes());
            } else {
                bytes.extend_from_slice(&(*unix as i32).to_be_bytes());
            }
        }
        for (_, index) in &self.transitions {
            bytes.push(*index);
        }
        for (position, (offset, is_dst)) in self.types.iter().enumerate() {
            bytes.extend_from_slice(&offset.to_be_bytes());
            bytes.push(u8::from(*is_dst));
            bytes.push(position as u8);
        }
        bytes.extend(std::iter::repeat_n(b'X', self.types.len()));
        bytes
    }
}

/// Great Britain: standard UTC, summer time +1h, spring forward 2026-03-29T01:00Z.
fn british_time() -> Vec<u8> {
    TzifBuilder::new()
        .with_type(0, false)
        .with_type(3600, true)
        .at(1_774_746_000, 1)
        .at(1_792_890_000, 0)
        .build()
}

#[test]
fn offsets_follow_the_stored_transition_table() {
    let zone = TimeZone::parse(&british_time()).expect("parse");
    assert_eq!(zone.offset_seconds_at(1_774_745_999), 0);
    assert_eq!(zone.offset_seconds_at(1_774_746_000), 3600);
    assert_eq!(zone.offset_seconds_at(1_792_889_999), 3600);
    assert_eq!(zone.offset_seconds_at(1_792_890_000), 0);
}

#[test]
fn instants_before_the_first_transition_use_the_first_standard_type() {
    let zone = TimeZone::parse(&british_time()).expect("parse");
    assert_eq!(zone.offset_seconds_at(0), 0);
    assert_eq!(zone.offset_seconds_at(-5_000_000_000), 0);
}

#[test]
fn a_spring_forward_skips_the_local_hour_that_never_happens() {
    let zone = TimeZone::parse(&british_time()).expect("parse");
    let before = zone.local_at(1_774_745_999).expect("local");
    let after = zone.local_at(1_774_746_000).expect("local");
    assert_eq!(before.minute_of_day, 59);
    assert_eq!(after.minute_of_day, 120);
    assert_eq!(before.day, after.day);
}

#[test]
fn a_fall_back_repeats_the_local_hour_with_the_standard_offset() {
    let zone = TimeZone::parse(&british_time()).expect("parse");
    let summer = zone.local_at(1_792_889_999).expect("local");
    let winter = zone.local_at(1_792_890_000).expect("local");
    assert_eq!(summer.minute_of_day, 119);
    assert_eq!(winter.minute_of_day, 60);
    assert_eq!(summer.day, winter.day);
}

#[test]
fn a_southern_hemisphere_zone_keeps_its_daylight_saving_over_the_new_year() {
    let sydney = TzifBuilder::new()
        .with_type(36_000, false)
        .with_type(39_600, true)
        .at(1_759_500_000, 1)
        .at(1_775_224_800, 0)
        .build();
    let zone = TimeZone::parse(&sydney).expect("parse");
    assert_eq!(zone.offset_seconds_at(1_767_225_600), 39_600);
    let local = zone.local_at(1_767_225_600).expect("local");
    assert_eq!((local.year, local.month, local.day), (2026, 1, 1));
    assert_eq!(local.minute_of_day, 11 * 60);
}

#[test]
fn a_fixed_offset_zone_needs_no_transitions() {
    let bytes = TzifBuilder::new().with_type(-18_000, false).build();
    let zone = TimeZone::parse(&bytes).expect("parse");
    assert_eq!(zone.offset_seconds_at(1_767_225_600), -18_000);
}

#[test]
fn the_local_day_boundary_is_reported_as_a_utc_instant() {
    let zone = TimeZone::parse(&british_time()).expect("parse");
    let noon_bst = 1_782_000_000;
    let local = zone.local_at(noon_bst).expect("local");
    assert_eq!(
        zone.local_day_start(&local),
        noon_bst - local.seconds_of_day()
    );
}

#[test]
fn a_zone_name_that_escapes_the_database_directory_is_refused() {
    for name in [
        "../../etc/passwd",
        "/etc/passwd",
        "Europe/../../etc/shadow",
        "Europe/London\0",
        "",
        "Europe/Lon don",
    ] {
        assert!(
            TimeZone::load(name).is_err(),
            "{name:?} must not resolve to a zone"
        );
    }
}

#[test]
fn a_truncated_or_foreign_file_is_refused() {
    assert!(TimeZone::parse(b"").is_err());
    assert!(TimeZone::parse(b"NOTTZif").is_err());
    let mut short = british_time();
    short.truncate(30);
    assert!(TimeZone::parse(&short).is_err());
}

#[test]
fn the_installed_database_resolves_london_across_its_2026_transitions() {
    let Ok(zone) = TimeZone::load("Europe/London") else {
        return;
    };
    assert_eq!(zone.offset_seconds_at(1_774_745_999), 0);
    assert_eq!(zone.offset_seconds_at(1_774_746_000), 3600);
    assert_eq!(zone.offset_seconds_at(1_792_890_000), 0);
}

#[test]
fn the_installed_database_resolves_new_york_across_its_2026_transitions() {
    let Ok(zone) = TimeZone::load("America/New_York") else {
        return;
    };
    assert_eq!(zone.offset_seconds_at(1_772_953_199), -18_000);
    assert_eq!(zone.offset_seconds_at(1_772_953_200), -14_400);
    assert_eq!(zone.offset_seconds_at(1_793_512_800), -18_000);
}

#[test]
fn the_next_local_midnight_survives_both_daylight_saving_shifts() {
    let zone = TimeZone::parse(&british_time()).expect("parse");
    let spring_forward_midnight = 1_774_742_400;
    let next = zone
        .next_local_midnight(spring_forward_midnight)
        .expect("boundary");
    assert_eq!(next, 1_774_825_200);
    assert_eq!(
        next - spring_forward_midnight,
        82_800,
        "a 23-hour local day"
    );
    let inside_summer = 1_782_000_000;
    let boundary = zone.next_local_midnight(inside_summer).expect("boundary");
    let local = zone.local_at(boundary).expect("local");
    assert_eq!(local.seconds_of_day(), 0);
    assert!(boundary > inside_summer && boundary - inside_summer <= 86_400);
}

/// BH-39: the current New York rule started in 2007, so a slim file records nothing after it.
fn slim_new_york() -> Vec<u8> {
    TzifBuilder::new()
        .with_type(-18_000, false)
        .with_type(-14_400, true)
        .at(1_173_596_400, 1)
        .at(1_194_156_000, 0)
        .build_slim("EST5EDT,M3.2.0,M11.1.0")
}

#[test]
fn bh_39_a_slim_zone_reads_daylight_saving_from_its_footer() {
    let zone = TimeZone::parse(&slim_new_york()).expect("parse");
    assert_eq!(zone.offset_seconds_at(1_782_907_200), -14_400, "2026-07-01");
    assert!(zone.is_daylight_saving_at(1_782_907_200));
    assert_eq!(zone.offset_seconds_at(1_768_478_400), -18_000, "2026-01-15");
    assert_eq!(zone.offset_seconds_at(2_224_756_800), -14_400, "2040-07-01");
}

#[test]
fn bh_39_the_local_day_boundary_follows_the_footer_rule_too() {
    let zone = TimeZone::parse(&slim_new_york()).expect("parse");
    // 2026-11-01 is the local day the footer's autumn change falls in: 25 hours long.
    let inside = 1_793_490_000;
    let next = zone.next_local_midnight(inside).expect("boundary");
    let start = zone.local_day_start(&zone.local_at(inside).expect("local"));
    assert_eq!(next - start, 90_000, "a 25-hour local day");
}
