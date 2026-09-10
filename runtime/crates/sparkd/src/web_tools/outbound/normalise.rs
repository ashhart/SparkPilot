//! Bring text to one canonical form before any pattern is matched, so re-encoding cannot hide a value.

use unicode_normalization::UnicodeNormalization as _;

/// How many layers of percent-encoding are peeled before the text is called deliberately obscured.
pub const MAX_DECODE_PASSES: usize = 4;

/// The form every class is matched against, and whether encoding survived the bound.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Canonical {
    pub text: String,
    /// True when `%XX` sequences remained after the last pass, so what they carry was never legible.
    pub still_encoded: bool,
}

/// Decode to a fixed point, normalise to NFKC, then fold every Unicode decimal digit to ASCII.
pub fn canonical(text: &str) -> Canonical {
    let mut current = text.to_owned();
    for _ in 0..MAX_DECODE_PASSES {
        let next = decode_percent(&current);
        if next == current {
            break;
        }
        current = next;
    }
    let still_encoded = has_escape(&current);
    let normalised: String = current.nfkc().collect();
    Canonical {
        text: fold_digits(&normalised),
        still_encoded,
    }
}

/// Percent-encoding is how an injected page would hide a value in an address.
fn decode_percent(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let pair = std::str::from_utf8(&bytes[index + 1..index + 3]).ok();
            if let Some(value) = pair.and_then(|pair| u8::from_str_radix(pair, 16).ok()) {
                out.push(value);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A `%` followed by two hexadecimal digits: a layer the decoder did not get to.
fn has_escape(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.windows(3).any(|window| {
        window[0] == b'%' && window[1].is_ascii_hexdigit() && window[2].is_ascii_hexdigit()
    })
}

/// Every decimal digit reads as the ASCII digit it means, whatever script wrote it.
fn fold_digits(text: &str) -> String {
    text.chars()
        .map(|character| {
            if character.is_ascii() {
                character
            } else {
                fold(character)
            }
        })
        .collect()
}

fn fold(character: char) -> char {
    let value = character as u32;
    let index = match ND_ZEROS.binary_search(&value) {
        Ok(_) => return '0',
        Err(0) => return character,
        Err(index) => index - 1,
    };
    let offset = value - ND_ZEROS[index];
    if offset < 10 {
        char::from_digit(offset, 10).unwrap_or(character)
    } else {
        character
    }
}

/// The first code point of every Unicode `Nd` block; each block runs ten code points in value order.
const ND_ZEROS: &[u32] = &[
    0x0030, 0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66, 0x0AE6, 0x0B66, 0x0BE6, 0x0C66, 0x0CE6,
    0x0D66, 0x0DE6, 0x0E50, 0x0ED0, 0x0F20, 0x1040, 0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80,
    0x1A90, 0x1B50, 0x1BB0, 0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900, 0xA9D0, 0xA9F0, 0xAA50, 0xABF0,
    0xFF10, 0x104A0, 0x10D30, 0x10D40, 0x11066, 0x110F0, 0x11136, 0x111D0, 0x112F0, 0x11450,
    0x114D0, 0x11650, 0x116C0, 0x116D0, 0x116DA, 0x11730, 0x118E0, 0x11950, 0x11BF0, 0x11C50,
    0x11D50, 0x11DA0, 0x11F50, 0x16130, 0x16A60, 0x16AC0, 0x16B50, 0x16D70, 0x1CCF0, 0x1D7CE,
    0x1D7D8, 0x1D7E2, 0x1D7EC, 0x1D7F6, 0x1E140, 0x1E2F0, 0x1E4F0, 0x1E5F1, 0x1E950, 0x1FBF0,
];
