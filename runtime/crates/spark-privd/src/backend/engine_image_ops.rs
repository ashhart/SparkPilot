use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    plan_only: bool,
    image: engine_image::EngineImage<'_>,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::EnsureEngineImage { image_digest, .. } => {
            if !valid_pinned_image(image_digest) {
                return Err(BackendError::InvalidInput(
                    "engine image must be pinned by sha256 digest".into(),
                ));
            }
            if plan_only {
                return Ok(PrivilegedResponse {
                    request_id,
                    accepted: true,
                    code: "planned".into(),
                    message: "engine image check/pull plan approved".into(),
                    details: serde_json::json!({
                        "image_digest": image_digest,
                        "pull_if_missing": true,
                    }),
                });
            }
            let already_present = image.image_is_present(image_digest)?;
            if !already_present {
                image.pull_image(image_digest)?;
            }
            if !image.image_is_present(image_digest)? {
                return Err(BackendError::Failure(
                    "container runtime did not retain the requested image digest".into(),
                ));
            }
            if image_digest == qwen::BASE {
                qwen::prepare_image()?;
            }
            Ok(PrivilegedResponse {
                request_id,
                accepted: true,
                code: "image_ready".into(),
                message: "digest-pinned engine image is available".into(),
                details: serde_json::json!({
                    "image_digest": image_digest,
                    "pulled": !already_present,
                }),
            })
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
