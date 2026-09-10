use super::*;
use serde_json::json;

const CALENDAR: &str = "<personal_context>\nnow: Fri 2026-09-05 09:00\nevent Fri 2026-09-05 19:00 Dinner at 21 Rue Blanche\n</personal_context>";

/// BH-36: the block the app puts in the system message never reaches the tool loop.
#[test]
fn the_personal_context_block_is_taken_out_of_the_system_turn() {
    let instruction = format!("You are helping the owner.\n\n{CALENDAR}\n\nAnswer briefly.");
    let (clean, _, stripped) = without_personal_context(Some(&instruction), Vec::new());
    let clean = clean.expect("an instruction");
    assert!(stripped);
    assert!(!clean.contains("personal_context"), "{clean}");
    assert!(!clean.contains("Rue Blanche"), "{clean}");
    assert!(clean.contains("You are helping the owner."), "{clean}");
    assert!(clean.contains("Answer briefly."), "{clean}");
}

/// BH-36: a user or assistant turn carrying the block is cleaned the same way, arrays included.
#[test]
fn the_personal_context_block_is_taken_out_of_every_turn() {
    let conversation = vec![
        json!({"role": "system", "content": CALENDAR}),
        json!({"role": "user", "content": [{"type": "text", "text": format!("here it is {CALENDAR}")}]}),
        json!({"role": "assistant", "content": "nothing personal here"}),
    ];
    let (_, cleaned, stripped) = without_personal_context(None, conversation);
    assert!(stripped);
    let rendered = serde_json::to_string(&cleaned).expect("json");
    assert!(!rendered.contains("personal_context"), "{rendered}");
    assert!(!rendered.contains("Rue Blanche"), "{rendered}");
    assert!(rendered.contains("nothing personal here"), "{rendered}");
}

/// BH-36: a forged opening tag with no close takes the rest of the turn with it rather than passing.
#[test]
fn an_unclosed_block_takes_the_rest_of_the_turn_with_it() {
    let text = format!("before {OPENING_TAG} secret dinner at 19:00");
    let (clean, _, stripped) = without_personal_context(Some(&text), Vec::new());
    assert!(stripped);
    assert_eq!(clean.as_deref(), Some("before "));
}

/// A transcript with nothing personal in it is handed on unchanged.
#[test]
fn a_transcript_without_the_block_is_left_alone() {
    let conversation = vec![json!({"role": "user", "content": "what is the weather"})];
    let (instruction, cleaned, stripped) =
        without_personal_context(Some("be brief"), conversation.clone());
    assert!(!stripped);
    assert_eq!(instruction.as_deref(), Some("be brief"));
    assert_eq!(cleaned, conversation);
}
