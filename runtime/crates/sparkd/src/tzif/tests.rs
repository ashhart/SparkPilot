use super::*;

/// Build TZif bodies so no test depends on which tzdata the host installed.
struct TzifBuilder {
    transitions: Vec<(i64, u8)>,
    types: Vec<(i32, bool)>,
    footer: Option<String>,
}

impl TzifBuilder {
    fn new() -> Self {
        Self {
            transitions: Vec::new(),
            types: Vec::new(),
            footer: None,
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

    fn footer(mut self, rule: &str) -> Self {
        self.footer = Some(rule.to_owned());
        self
    }

    fn header(&self, version: u8) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"TZif");
        bytes.push(version);
        bytes.extend_from_slice(&[0u8; 15]);
        for count in [
            0u32,
            0,
            0,
            self.transitions.len() as u32,
            self.types.len() as u32,
            self.types.len() as u32,
        ] {
            bytes.extend_from_slice(&count.to_be_bytes());
        }
        bytes
    }

    fn block(&self, wide: bool) -> Vec<u8> {
        let mut bytes = Vec::new();
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

    /// A version-1 body, which carries no footer at all.
    fn build_v1(&self) -> Vec<u8> {
        let mut bytes = self.header(0);
        bytes.extend(self.block(false));
        bytes
    }

    /// A version-2 body: the legacy block, the 64-bit block, then the POSIX rule.
    fn build_v2(&self) -> Vec<u8> {
        let mut bytes = self.header(b'2');
        bytes.extend(self.block(false));
        bytes.extend(self.header(b'2'));
        bytes.extend(self.block(true));
        bytes.push(b'\n');
        bytes.extend_from_slice(self.footer.clone().unwrap_or_default().as_bytes());
        bytes.push(b'\n');
        bytes
    }
}

/// What `zic -b slim` writes for America/New_York: the current rule started in 2007, the footer carries the rest.
fn slim_new_york() -> Vec<u8> {
    TzifBuilder::new()
        .with_type(-18_000, false)
        .with_type(-14_400, true)
        .at(1_173_596_400, 1)
        .at(1_194_156_000, 0)
        .footer("EST5EDT,M3.2.0,M11.1.0")
        .build_v2()
}

#[test]
fn bh_39_a_slim_zone_follows_its_footer_rule_the_summer_after_the_table_ends() {
    let zone = Tzif::parse(&slim_new_york()).expect("parse");
    assert_eq!(zone.offset_at(1_782_907_200), -14_400, "2026-07-01 is EDT");
    assert_eq!(zone.offset_at(1_768_478_400), -18_000, "2026-01-15 is EST");
    assert!(zone.is_daylight_saving_at(1_782_907_200));
    assert!(!zone.is_daylight_saving_at(1_768_478_400));
}

#[test]
fn bh_39_the_footer_still_governs_after_the_thirty_two_bit_horizon() {
    let zone = Tzif::parse(&slim_new_york()).expect("parse");
    assert_eq!(zone.offset_at(2_224_756_800), -14_400, "2040-07-01 is EDT");
    assert_eq!(zone.offset_at(2_210_241_600), -18_000, "2040-01-15 is EST");
    assert_eq!(zone.offset_at(2_152_162_799), -18_000);
    assert_eq!(zone.offset_at(2_152_162_800), -14_400);
}

#[test]
fn bh_39_the_footer_finds_the_exact_transition_instants_it_implies() {
    let zone = Tzif::parse(&slim_new_york()).expect("parse");
    assert_eq!(zone.offset_at(1_772_953_199), -18_000);
    assert_eq!(zone.offset_at(1_772_953_200), -14_400);
    assert_eq!(zone.offset_at(1_793_512_799), -14_400);
    assert_eq!(zone.offset_at(1_793_512_800), -18_000);
    assert_eq!(
        zone.transitions_between(1_767_225_600, 1_798_761_600),
        vec![1_772_953_200, 1_793_512_800]
    );
}

#[test]
fn a_southern_footer_keeps_daylight_saving_across_the_new_year() {
    let sydney = TzifBuilder::new()
        .with_type(36_000, false)
        .with_type(39_600, true)
        .at(1_759_500_000, 1)
        .footer("AEST-10AEDT,M10.1.0,M4.1.0/3")
        .build_v2();
    let zone = Tzif::parse(&sydney).expect("parse");
    // 2040-01-15T12:00Z is the middle of the southern summer.
    assert_eq!(zone.offset_at(2_210_241_600), 39_600);
    // 2040-07-01T12:00Z is the middle of the southern winter.
    assert_eq!(zone.offset_at(2_224_756_800), 36_000);
}

#[test]
fn a_footer_without_a_daylight_rule_is_a_fixed_offset_forever() {
    let bytes = TzifBuilder::new()
        .with_type(-18_000, false)
        .at(1_173_596_400, 0)
        .footer("EST5")
        .build_v2();
    let zone = Tzif::parse(&bytes).expect("parse");
    assert_eq!(zone.offset_at(2_224_756_800), -18_000);
    assert_eq!(zone.distinct_offsets(), vec![-18_000]);
}

#[test]
fn a_version_one_file_has_no_footer_and_keeps_its_last_period() {
    let bytes = TzifBuilder::new()
        .with_type(0, false)
        .with_type(3_600, true)
        .at(1_774_746_000, 1)
        .build_v1();
    let zone = Tzif::parse(&bytes).expect("parse");
    assert_eq!(zone.offset_at(2_224_756_800), 3_600);
}

#[test]
fn an_unreadable_footer_leaves_the_transition_table_in_charge() {
    let bytes = TzifBuilder::new()
        .with_type(-18_000, false)
        .at(1_173_596_400, 0)
        .footer("not a rule")
        .build_v2();
    let zone = Tzif::parse(&bytes).expect("parse");
    assert_eq!(zone.offset_at(2_224_756_800), -18_000);
}

#[test]
fn a_truncated_or_foreign_file_is_refused() {
    assert_eq!(Tzif::parse(b""), Err(Malformed));
    assert_eq!(Tzif::parse(b"NOTTZif"), Err(Malformed));
    let mut short = slim_new_york();
    short.truncate(30);
    assert_eq!(Tzif::parse(&short), Err(Malformed));
}

#[test]
fn quoted_names_signed_offsets_and_julian_days_all_parse() {
    let bytes = TzifBuilder::new()
        .with_type(-12_600, false)
        .with_type(-9_000, true)
        .at(1_173_596_400, 0)
        .footer("<-0330>3:30<-0230>2:30,J60,J300")
        .build_v2();
    let zone = Tzif::parse(&bytes).expect("parse");
    assert_eq!(
        zone.offset_at(1_768_478_400),
        -12_600,
        "January is standard"
    );
    assert_eq!(zone.offset_at(1_782_907_200), -9_000, "July is daylight");
}
