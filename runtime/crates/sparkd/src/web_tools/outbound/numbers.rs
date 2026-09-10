//! Read a written number as a payment card or a telephone number, and refuse to read three years as one.

use super::{Finding, Reading, runs};

/// Digit counts a payment card is written with, before the check digit is tested.
const CARD_LENGTHS: [usize; 3] = [15, 16, 19];
/// A telephone number carries this many digits, wherever it is dialled.
const MIN_TELEPHONE_DIGITS: usize = 9;
const MAX_TELEPHONE_DIGITS: usize = 15;
/// More groups than any written telephone number uses.
const MAX_GROUPS: usize = 5;

/// Judge every candidate span as a card first and then as a telephone number.
pub fn scan(text: &str, reading: Reading) -> Option<Finding> {
    for span in runs(text, |character| {
        character.is_ascii_digit() || "+-() ".contains(character)
    }) {
        let groups = runs(span, |character| character.is_ascii_digit());
        let digits: String = groups.concat();
        if CARD_LENGTHS.contains(&digits.len()) && luhn(&digits) {
            return Some(Finding::PaymentCard);
        }
        let length = digits.len();
        if (MIN_TELEPHONE_DIGITS..=MAX_TELEPHONE_DIGITS).contains(&length)
            && is_telephone(span, &groups, reading)
        {
            return Some(Finding::PhoneNumber);
        }
    }
    None
}

/// A span is a telephone number only in a shape a person would actually write one in.
fn is_telephone(span: &str, groups: &[&str], reading: Reading) -> bool {
    if groups.is_empty() || groups.len() > MAX_GROUPS {
        return false;
    }
    let span = span.trim();
    let international = span.starts_with('+');
    // The (area) prefix, which no run of years or window sizes is ever written with.
    let parenthesised = span.starts_with('(') && span.contains(')');
    let gaps = separators(span);
    let hyphenated = !gaps.is_empty() && gaps.iter().all(|gap| gap.contains('-'));
    // Two groups read as one number; three space-separated groups read as three numbers.
    let paired = groups.len() == 2 && (3..=6).contains(&groups[0].len());
    let explicit = international || parenthesised || hyphenated;
    match reading {
        Reading::Free => explicit || paired || groups.len() == 1,
        Reading::Path | Reading::Host => explicit,
    }
}

/// What was written between one digit group and the next, with nothing trimmed away.
fn separators(span: &str) -> Vec<&str> {
    let mut gaps = Vec::new();
    let mut start: Option<usize> = None;
    let mut after_digits = false;
    for (index, character) in span.char_indices() {
        if character.is_ascii_digit() {
            if let Some(from) = start.take()
                && after_digits
            {
                gaps.push(&span[from..index]);
            }
            after_digits = true;
        } else if start.is_none() {
            start = Some(index);
        }
    }
    gaps
}

fn luhn(digits: &str) -> bool {
    let mut sum = 0_u32;
    for (index, digit) in digits.bytes().rev().enumerate() {
        let mut value = u32::from(digit - b'0');
        if !index.is_multiple_of(2) {
            value *= 2;
            if value > 9 {
                value -= 9;
            }
        }
        sum += value;
    }
    sum.is_multiple_of(10)
}
