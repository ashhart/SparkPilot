use super::*;
use crate::auth::AccessAuthentication;
use crate::workload_adoption::adoption_preview::mismatch_blocker;

fn principal(role: &str) -> Principal {
    Principal {
        device_id: uuid::Uuid::new_v4(),
        role: role.into(),
        access_authentication: AccessAuthentication::DeviceSignature,
        user_presence: None,
    }
}

#[test]
fn only_owner_and_administrator_may_review_or_change_adoption() {
    for role in ["observer", "user", "developer"] {
        let (status, Json(body)) = require_administrator(&principal(role)).unwrap_err();
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(body["error"]["code"], "ROLE_FORBIDDEN");
    }
    for role in ["administrator", "owner"] {
        assert!(require_administrator(&principal(role)).is_ok());
    }
}

#[test]
fn mismatch_copy_never_repeats_inspected_values_or_secrets() {
    let rendered = serde_json::to_string(&mismatch_blocker(
        "CONFIGURATION_MISMATCH:VLLM_API_KEY=do-not-return",
    ))
    .unwrap();
    assert!(!rendered.contains("VLLM_API_KEY"));
    assert!(!rendered.contains("do-not-return"));
    assert!(rendered.contains("signed recipe"));
}
