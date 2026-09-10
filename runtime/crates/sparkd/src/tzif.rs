//! One TZif reader for the whole daemon: the transition table, and the POSIX rule its version-2 footer carries for every instant after that table ends.

#[path = "tzif/posix.rs"]
mod posix;

/// The header every TZif block opens with.
const HEADER_BYTES: usize = 44;

/// Refuse zone files larger than this; real entries are a few kilobytes.
pub const MAX_ZONE_FILE_BYTES: u64 = 1 << 20;

/// The file is not a TZif file this reader can use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Malformed;

/// One zone: what the table records, and what the footer says happens afterwards.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tzif {
    transitions: Vec<i64>,
    transition_types: Vec<u8>,
    offsets: Vec<i32>,
    is_dst: Vec<bool>,
    footer: Option<posix::PosixTz>,
}

impl Tzif {
    /// A zone with one offset and no seasonal change, for callers that need no file.
    pub fn fixed(offset_seconds: i32) -> Self {
        Self {
            transitions: Vec::new(),
            transition_types: Vec::new(),
            offsets: vec![offset_seconds],
            is_dst: vec![false],
            footer: None,
        }
    }

    /// Parse a TZif body, preferring the 64-bit block and its footer when the file carries one.
    pub fn parse(bytes: &[u8]) -> Result<Self, Malformed> {
        let first = Header::read(bytes)?;
        if first.version == 0 {
            return Self::read_block(bytes, HEADER_BYTES, &first, 4, None);
        }
        let second_start = HEADER_BYTES
            .checked_add(first.data_block_length(4))
            .ok_or(Malformed)?;
        let tail = bytes.get(second_start..).ok_or(Malformed)?;
        let second = Header::read(tail)?;
        let block_start = second_start.checked_add(HEADER_BYTES).ok_or(Malformed)?;
        let footer_start = block_start
            .checked_add(second.data_block_length(8))
            .ok_or(Malformed)?;
        let footer = read_footer(bytes, footer_start);
        Self::read_block(bytes, block_start, &second, 8, footer)
    }

    /// The UTC offset in force at an absolute instant.
    pub fn offset_at(&self, unix: i64) -> i32 {
        match self.footer_at(unix) {
            Some(footer) => footer.offset_at(unix),
            None => self
                .offsets
                .get(usize::from(self.type_index_at(unix)))
                .copied()
                .unwrap_or(0),
        }
    }

    /// Whether daylight saving is in force at an absolute instant.
    pub fn is_daylight_saving_at(&self, unix: i64) -> bool {
        match self.footer_at(unix) {
            Some(footer) => footer.is_daylight_saving_at(unix),
            None => self
                .is_dst
                .get(usize::from(self.type_index_at(unix)))
                .copied()
                .unwrap_or(false),
        }
    }

    /// Every offset this zone can use, so a local reading can be tried against each.
    pub fn distinct_offsets(&self) -> Vec<i32> {
        let mut offsets = vec![self.initial_offset()];
        let table = self.offsets.iter().copied();
        let rule = self.footer.iter().flat_map(posix::PosixTz::offsets);
        for offset in table.chain(rule) {
            if !offsets.contains(&offset) {
                offsets.push(offset);
            }
        }
        offsets
    }

    /// Every instant in `[from, to)` at which this zone changes its clock, table and footer alike.
    pub fn transitions_between(&self, from: i64, to: i64) -> Vec<i64> {
        let mut found = self
            .transitions
            .iter()
            .copied()
            .filter(|instant| (from..to).contains(instant))
            .collect::<Vec<_>>();
        if let Some(footer) = &self.footer {
            let last = self.transitions.last().copied().unwrap_or(i64::MIN);
            for year in years_between(from, to) {
                found.extend(
                    footer
                        .transitions_in_year(year)
                        .into_iter()
                        .filter(|instant| *instant >= last && (from..to).contains(instant)),
                );
            }
        }
        found.sort_unstable();
        found.dedup();
        found
    }

    /// The offset used before the first recorded transition: the first standard type.
    fn initial_offset(&self) -> i32 {
        self.offsets
            .get(usize::from(self.first_standard_type()))
            .copied()
            .unwrap_or(0)
    }

    /// The footer governs every instant from the last recorded transition onwards.
    fn footer_at(&self, unix: i64) -> Option<&posix::PosixTz> {
        let footer = self.footer.as_ref()?;
        match self.transitions.last() {
            Some(last) if unix < *last => None,
            _ => Some(footer),
        }
    }

    fn type_index_at(&self, unix: i64) -> u8 {
        match self.transitions.binary_search(&unix) {
            Ok(position) => self.transition_types.get(position).copied().unwrap_or(0),
            Err(0) => self.first_standard_type(),
            Err(position) => self
                .transition_types
                .get(position - 1)
                .copied()
                .unwrap_or(0),
        }
    }

    /// Before the first recorded transition a zone uses its first non-daylight type.
    fn first_standard_type(&self) -> u8 {
        self.is_dst
            .iter()
            .position(|dst| !dst)
            .unwrap_or(0)
            .min(usize::from(u8::MAX)) as u8
    }

    fn read_block(
        bytes: &[u8],
        start: usize,
        header: &Header,
        time_size: usize,
        footer: Option<posix::PosixTz>,
    ) -> Result<Self, Malformed> {
        let end = start
            .checked_add(header.data_block_length(time_size))
            .ok_or(Malformed)?;
        let block = bytes.get(start..end).ok_or(Malformed)?;
        let mut cursor = 0usize;
        let mut transitions = Vec::with_capacity(header.timecnt);
        for _ in 0..header.timecnt {
            let slice = block.get(cursor..cursor + time_size).ok_or(Malformed)?;
            transitions.push(read_signed(slice));
            cursor += time_size;
        }
        let transition_types = block
            .get(cursor..cursor + header.timecnt)
            .ok_or(Malformed)?
            .to_vec();
        cursor += header.timecnt;
        let mut offsets = Vec::with_capacity(header.typecnt);
        let mut is_dst = Vec::with_capacity(header.typecnt);
        for _ in 0..header.typecnt {
            let slice = block.get(cursor..cursor + 6).ok_or(Malformed)?;
            offsets.push(i32::from_be_bytes([slice[0], slice[1], slice[2], slice[3]]));
            is_dst.push(slice[4] != 0);
            cursor += 6;
        }
        if offsets.is_empty()
            || transition_types
                .iter()
                .any(|index| usize::from(*index) >= offsets.len())
        {
            return Err(Malformed);
        }
        if transitions.windows(2).any(|pair| pair[0] > pair[1]) {
            return Err(Malformed);
        }
        Ok(Self {
            transitions,
            transition_types,
            offsets,
            is_dst,
            footer,
        })
    }
}

/// The footer is a newline, a POSIX TZ string and another newline; anything else leaves the table alone.
fn read_footer(bytes: &[u8], start: usize) -> Option<posix::PosixTz> {
    let tail = bytes.get(start..)?;
    let text = tail.strip_prefix(b"\n")?;
    let end = text.iter().position(|byte| *byte == b'\n')?;
    posix::PosixTz::parse(std::str::from_utf8(text.get(..end)?).ok()?)
}

fn years_between(from: i64, to: i64) -> std::ops::RangeInclusive<i32> {
    let year = |unix: i64| {
        time::OffsetDateTime::from_unix_timestamp(unix)
            .map(|moment| moment.year())
            .unwrap_or(1970)
    };
    (year(from) - 1)..=(year(to) + 1)
}

fn read_signed(slice: &[u8]) -> i64 {
    if slice.len() == 4 {
        return i64::from(i32::from_be_bytes([slice[0], slice[1], slice[2], slice[3]]));
    }
    let mut buffer = [0u8; 8];
    buffer.copy_from_slice(slice);
    i64::from_be_bytes(buffer)
}

struct Header {
    version: u8,
    timecnt: usize,
    typecnt: usize,
    charcnt: usize,
    leapcnt: usize,
    isstdcnt: usize,
    isutcnt: usize,
}

impl Header {
    fn read(bytes: &[u8]) -> Result<Header, Malformed> {
        let head = bytes.get(..HEADER_BYTES).ok_or(Malformed)?;
        if &head[..4] != b"TZif" {
            return Err(Malformed);
        }
        let version = match head[4] {
            0 => 0,
            b'2' => 2,
            b'3' => 3,
            b'4' => 4,
            _ => return Err(Malformed),
        };
        let count = |index: usize| -> usize {
            u32::from_be_bytes([
                head[20 + index * 4],
                head[21 + index * 4],
                head[22 + index * 4],
                head[23 + index * 4],
            ]) as usize
        };
        let header = Header {
            version,
            isutcnt: count(0),
            isstdcnt: count(1),
            leapcnt: count(2),
            timecnt: count(3),
            typecnt: count(4),
            charcnt: count(5),
        };
        if header.typecnt == 0 || header.typecnt > 1024 || header.timecnt > 1 << 20 {
            return Err(Malformed);
        }
        Ok(header)
    }

    fn data_block_length(&self, time_size: usize) -> usize {
        self.timecnt * (time_size + 1)
            + self.typecnt * 6
            + self.charcnt
            + self.leapcnt * (time_size + 4)
            + self.isstdcnt
            + self.isutcnt
    }
}

#[cfg(test)]
#[path = "tzif/tests.rs"]
mod tests;
