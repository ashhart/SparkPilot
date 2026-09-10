use super::*;

/// 2026-06-15T12:00:00Z, a summer instant in both hemispheres tested here.
const SUMMER: i64 = 1_781_524_800;
/// 2026-01-15T12:00:00Z, a winter instant.
const WINTER: i64 = 1_768_478_400;

#[test]
fn a_zone_name_that_could_escape_the_database_is_refused() {
    for name in [
        "",
        "/",
        "/etc/passwd",
        "../../etc/passwd",
        "Europe/../../etc/shadow",
        "Europe/",
        "Europe//London",
        "Europe/London/Extra/Deep",
        "Europe/Lon don",
        "Europe/Lon;don",
        "-Europe/London",
    ] {
        assert!(!valid_name(name), "{name} must be refused");
    }
    for name in [
        "UTC",
        "Europe/London",
        "America/New_York",
        "America/Argentina/Ushuaia",
    ] {
        assert!(valid_name(name), "{name} must be accepted");
    }
}

#[test]
fn a_missing_or_unreadable_zone_is_named_rather_than_silently_utc() {
    let root = tempfile::tempdir().expect("temporary zone root");
    assert_eq!(
        Timezone::load_from(root.path(), "Europe/Atlantis"),
        Err(TimezoneError::Missing)
    );
    assert_eq!(
        Timezone::load_from(root.path(), "../escape"),
        Err(TimezoneError::Name)
    );
    std::fs::create_dir_all(root.path().join("Europe")).expect("zone directory");
    std::fs::write(root.path().join("Europe/Broken"), b"not a zone file").expect("zone file");
    assert_eq!(
        Timezone::load_from(root.path(), "Europe/Broken"),
        Err(TimezoneError::Malformed)
    );
    assert_eq!(TimezoneError::Missing.code(), "AUTOMATION_TIMEZONE_UNKNOWN");
    assert_eq!(
        TimezoneError::Malformed.code(),
        "AUTOMATION_TIMEZONE_UNREADABLE"
    );
}

#[test]
fn british_summer_time_moves_the_offset_and_utc_never_does() {
    let london = Timezone::load("Europe/London").expect("Europe/London is installed");
    assert_eq!(london.offset_at(WINTER), 0);
    assert_eq!(london.offset_at(SUMMER), 3_600);
    let utc = Timezone::load("UTC").expect("UTC is installed");
    assert_eq!(utc.offset_at(WINTER), 0);
    assert_eq!(utc.offset_at(SUMMER), 0);
    assert_eq!(Timezone::utc().offset_at(SUMMER), 0);
}

#[test]
fn new_york_is_five_hours_behind_in_winter_and_four_in_summer() {
    let york = Timezone::load("America/New_York").expect("America/New_York is installed");
    assert_eq!(york.offset_at(WINTER), -5 * 3_600);
    assert_eq!(york.offset_at(SUMMER), -4 * 3_600);
}

/// 2026-03-29T01:00:00Z is when London moves to BST; 01:30 local that morning never happens.
#[test]
fn a_local_time_inside_the_spring_forward_gap_fires_at_the_moment_the_gap_ends() {
    let london = Timezone::load("Europe/London").expect("Europe/London is installed");
    let transition = 1_774_746_000;
    assert_eq!(london.offset_at(transition - 1), 0);
    assert_eq!(london.offset_at(transition), 3_600);

    let local_reading = transition + 1_800;
    assert_eq!(london.local_to_unix(local_reading), transition);
    let before_the_gap = transition - 3_600;
    assert_eq!(london.local_to_unix(before_the_gap), before_the_gap);
}

/// 2026-10-25T01:00:00Z is when London returns to GMT; 01:30 local happens twice.
#[test]
fn a_local_time_inside_the_fall_back_overlap_fires_only_on_its_first_occurrence() {
    let london = Timezone::load("Europe/London").expect("Europe/London is installed");
    let transition = 1_792_890_000;
    assert_eq!(london.offset_at(transition - 1), 3_600);
    assert_eq!(london.offset_at(transition), 0);

    let ambiguous_local = transition + 1_800;
    let resolved = london.local_to_unix(ambiguous_local);
    assert_eq!(resolved, ambiguous_local - 3_600);
    assert_eq!(
        resolved + i64::from(london.offset_at(resolved)),
        ambiguous_local
    );
    let later = ambiguous_local;
    assert!(resolved < later, "the earlier occurrence must be chosen");
}

#[test]
fn an_ordinary_local_reading_round_trips_in_both_seasons() {
    let london = Timezone::load("Europe/London").expect("Europe/London is installed");
    for instant in [WINTER, SUMMER] {
        let local = instant + i64::from(london.offset_at(instant));
        assert_eq!(london.local_to_unix(local), instant);
    }
}

/// BH-39: a slim `America/New_York` records only the 2007 rule change; everything later is in the footer.
fn slim_new_york() -> Vec<u8> {
    let mut bytes = Vec::new();
    for wide in [false, true] {
        bytes.extend_from_slice(b"TZif2");
        bytes.extend_from_slice(&[0u8; 15]);
        for count in [0u32, 0, 0, 2, 2, 2] {
            bytes.extend_from_slice(&count.to_be_bytes());
        }
        for (unix, index) in [(1_173_596_400i64, 1u8), (1_194_156_000, 0)] {
            let _ = index;
            if wide {
                bytes.extend_from_slice(&unix.to_be_bytes());
            } else {
                bytes.extend_from_slice(&(unix as i32).to_be_bytes());
            }
        }
        bytes.extend_from_slice(&[1u8, 0]);
        for (position, (offset, is_dst)) in [(-18_000i32, 0u8), (-14_400, 1)].iter().enumerate() {
            bytes.extend_from_slice(&offset.to_be_bytes());
            bytes.push(*is_dst);
            bytes.push(position as u8);
        }
        bytes.extend_from_slice(b"XX");
    }
    bytes.extend_from_slice(b"\nEST5EDT,M3.2.0,M11.1.0\n");
    bytes
}

#[test]
fn bh_39_a_slim_zone_file_still_gives_the_right_offset_this_summer() {
    let root = tempfile::tempdir().expect("temporary zone root");
    std::fs::create_dir_all(root.path().join("America")).expect("zone directory");
    std::fs::write(root.path().join("America/New_York"), slim_new_york()).expect("zone file");
    let york = Timezone::load_from(root.path(), "America/New_York").expect("slim zone loads");
    // 2026-07-01T12:00:00Z is deep in eastern daylight time; the table stops in 2007.
    assert_eq!(york.offset_at(1_782_907_200), -14_400);
    assert_eq!(york.offset_at(WINTER), -18_000);
    // 2040 is past the 32-bit horizon every installed table stops at.
    assert_eq!(york.offset_at(2_224_756_800), -14_400);
}

#[test]
fn bh_39_a_footer_gap_and_overlap_resolve_like_a_recorded_transition() {
    let root = tempfile::tempdir().expect("temporary zone root");
    std::fs::create_dir_all(root.path().join("America")).expect("zone directory");
    std::fs::write(root.path().join("America/New_York"), slim_new_york()).expect("zone file");
    let york = Timezone::load_from(root.path(), "America/New_York").expect("slim zone loads");
    // 2026-03-08T07:00:00Z is when the footer moves New York to EDT; 02:30 local never happens.
    let spring_forward = 1_772_953_200;
    let missing_local = spring_forward + i64::from(york.offset_at(spring_forward - 1)) + 1_800;
    assert_eq!(york.local_to_unix(missing_local), spring_forward);
    // 2026-11-01T06:00:00Z returns it to EST; 01:30 local happens twice and the earlier one wins.
    let fall_back = 1_793_512_800;
    let ambiguous_local = fall_back + i64::from(york.offset_at(fall_back)) + 1_800;
    assert_eq!(
        york.local_to_unix(ambiguous_local),
        ambiguous_local + 14_400
    );
}
