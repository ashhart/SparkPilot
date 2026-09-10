use super::*;

pub(super) fn execute(
    op: &PrivilegedOperation,
    network_rollbacks: &NetworkRollbackManager,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::ConfirmNetworkChange {
            configuration_id, ..
        } => {
            let resolution = network_rollbacks.confirm(*configuration_id)?;
            let (accepted, code, message) = match resolution {
                NetworkChangeResolution::Resolved => {
                    (true, "network_change_confirmed", "network change retained")
                }
                NetworkChangeResolution::Missing => (
                    false,
                    "NETWORK_CHANGE_NOT_PENDING",
                    "network change is no longer pending",
                ),
                NetworkChangeResolution::Executing => (
                    false,
                    "NETWORK_ROLLBACK_IN_PROGRESS",
                    "network rollback is already running",
                ),
            };
            Ok(PrivilegedResponse {
                request_id,
                accepted,
                code: code.into(),
                message: message.into(),
                details: serde_json::json!({
                    "configuration_id": configuration_id,
                    "resolved": matches!(resolution, NetworkChangeResolution::Resolved),
                    "confirmed": matches!(resolution, NetworkChangeResolution::Resolved),
                }),
            })
        }
        PrivilegedOperation::RollbackNetworkChange {
            configuration_id, ..
        } => {
            let resolution = network_rollbacks.rollback(*configuration_id)?;
            let (accepted, code, message) = match resolution {
                NetworkChangeResolution::Resolved => (
                    true,
                    "network_change_rolled_back",
                    "network change restored",
                ),
                NetworkChangeResolution::Missing => (
                    false,
                    "NETWORK_CHANGE_NOT_PENDING",
                    "network change is no longer pending",
                ),
                NetworkChangeResolution::Executing => (
                    false,
                    "NETWORK_ROLLBACK_IN_PROGRESS",
                    "network rollback is already running",
                ),
            };
            Ok(PrivilegedResponse {
                request_id,
                accepted,
                code: code.into(),
                message: message.into(),
                details: serde_json::json!({
                    "configuration_id": configuration_id,
                    "resolved": matches!(resolution, NetworkChangeResolution::Resolved),
                    "rolled_back": matches!(resolution, NetworkChangeResolution::Resolved),
                }),
            })
        }
        _ => Err(BackendError::InvalidInput(
            "operation does not belong to this control boundary".into(),
        )),
    }
}
