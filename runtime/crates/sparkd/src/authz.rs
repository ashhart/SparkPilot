//! Authorize against stored resource ownership and fail sensitive mutations closed if their audit decision cannot be recorded.

use axum::Json;
use axum::http::StatusCode;
use serde_json::{Value, json};

use crate::audit::AuditDraft;
use crate::auth::Principal;
use crate::capability::{
    Capability, DenyReason, Presence, ProjectPermission, Request, ResourceScope, Role, evaluate,
};
use crate::state::AppState;

/// Shared denied-action error envelope.
pub type Denial = (StatusCode, Json<Value>);

fn envelope(code: &str, message: &str, status: StatusCode) -> Denial {
    (
        status,
        Json(json!({
            "error": {
                "code": code,
                "message": message,
                "request_id": crate::route::current_request_id(),
            }
        })),
    )
}

fn deny_envelope(reason: DenyReason) -> Denial {
    let status = match reason {
        DenyReason::UserPresenceRequired => StatusCode::FORBIDDEN,
        _ => StatusCode::FORBIDDEN,
    };
    envelope(reason.code(), reason.message(), status)
}

fn internal(message: &str) -> Denial {
    envelope("INTERNAL_ERROR", message, StatusCode::INTERNAL_SERVER_ERROR)
}

/// The only inference resources a guest may reach; every other one is refused by name.
const GUEST_INFERENCE_RESOURCES: &[&str] = &["v1/chat/completions", "v1/responses", "v1/models"];

/// A guest holds InferenceRun for the chat gateway alone, so a new inference route is closed to guests by default.
fn guest_reaches(capability: Capability, resource: Option<&str>) -> bool {
    if capability != Capability::InferenceRun {
        return true;
    }
    resource.is_some_and(|resource| GUEST_INFERENCE_RESOURCES.contains(&resource))
}

/// One authorisation attempt. Build with [`AppState::require`].
pub struct Authorization<'a> {
    state: &'a AppState,
    principal: &'a Principal,
    capability: Capability,
    scope: ResourceScope,
    resource: Option<String>,
    details: Value,
}

impl AppState {
    /// Begin an authorisation for `capability` at node scope.
    pub fn require<'a>(
        &'a self,
        principal: &'a Principal,
        capability: Capability,
    ) -> Authorization<'a> {
        Authorization {
            state: self,
            principal,
            capability,
            scope: ResourceScope::Node,
            resource: None,
            details: json!({}),
        }
    }
}

impl<'a> Authorization<'a> {
    /// Scope project actions using the resource's stored project ID, never the URL alone.
    pub fn in_project(mut self, project_id: uuid::Uuid) -> Self {
        self.scope = ResourceScope::Project { project_id };
        self
    }

    /// Scope the action to another device identity, for the authority ceiling.
    pub fn on_device(mut self, target_role: Role) -> Self {
        self.scope = ResourceScope::Device { target_role };
        self
    }

    /// Scope the action to a build job and the project that owns it.
    pub fn on_build(mut self, project_id: uuid::Uuid, requested_by: uuid::Uuid) -> Self {
        self.scope = ResourceScope::Build {
            project_id,
            requested_by,
        };
        self
    }

    /// Name the resource in the audit record.
    pub fn resource(mut self, resource: impl Into<String>) -> Self {
        self.resource = Some(resource.into());
        self
    }

    /// Attach audit detail without secrets or prompt bodies.
    pub fn details(mut self, details: Value) -> Self {
        self.details = details;
        self
    }

    /// Authorize without presence; elevated handlers must verify the separate presence key and call check_with_verified_presence.
    pub fn check(self) -> Result<(), Denial> {
        self.check_with_verified_presence(Presence::Absent)
    }

    /// Authorize with presence already bound to the authenticated request and the registered presence key.
    pub(crate) fn check_with_verified_presence(self, presence: Presence) -> Result<(), Denial> {
        let role = Role::parse(&self.principal.role);
        let project_permission = match &self.scope {
            ResourceScope::Project { project_id } => self.lookup_permission(project_id)?,
            ResourceScope::Build { project_id, .. } => self.lookup_permission(project_id)?,
            _ => None,
        };

        if role == Role::Guest && !guest_reaches(self.capability, self.resource.as_deref()) {
            let mut details = self.details.clone();
            if let Some(object) = details.as_object_mut() {
                object.insert(
                    "deny_reason".into(),
                    json!(DenyReason::RoleForbidden.code()),
                );
            }
            self.write_audit("refused", &details)?;
            return Err(deny_envelope(DenyReason::RoleForbidden));
        }
        let outcome = evaluate(&Request {
            capability: self.capability,
            scope: self.scope.clone(),
            role,
            device_id: self.principal.device_id,
            project_permission,
            presence,
            policy: self.state.capability_policy,
        });

        let (result, reason) = match outcome {
            Ok(()) => ("accepted", None),
            Err(reason) => ("refused", Some(reason)),
        };

        let mut details = self.details.clone();
        if let Some(reason) = reason
            && let Some(object) = details.as_object_mut()
        {
            object.insert("deny_reason".into(), json!(reason.code()));
        }
        if let ResourceScope::Project { project_id } | ResourceScope::Build { project_id, .. } =
            &self.scope
            && let Some(object) = details.as_object_mut()
        {
            object.insert("project_id".into(), json!(project_id.to_string()));
        }

        self.write_audit(result, &details)?;

        match reason {
            None => Ok(()),
            Some(reason) => Err(deny_envelope(reason)),
        }
    }

    fn lookup_permission(
        &self,
        project_id: &uuid::Uuid,
    ) -> Result<Option<ProjectPermission>, Denial> {
        let Some(database) = self.state.database.as_ref() else {
            return Err(internal("no database"));
        };
        let conn = database.lock();
        let stored = crate::store::project_permission(&conn, project_id, &self.principal.device_id)
            .map_err(|error| {
                tracing::error!(%error, "project membership lookup failed");
                internal("membership lookup failed")
            })?;
        // An unrecognised stored permission is treated as no membership.
        Ok(stored.as_deref().and_then(ProjectPermission::parse))
    }

    fn write_audit(&self, result: &str, details: &Value) -> Result<(), Denial> {
        let Some(database) = self.state.database.as_ref() else {
            // Refuse sensitive actions when unavailable storage prevents recording their audit decision.
            return if self.capability.is_sensitive_mutation() {
                Err(crate::audit::unavailable_envelope(
                    crate::store::StoreError::Audit("audit storage unavailable".into()),
                ))
            } else {
                Ok(())
            };
        };
        let conn = database.lock();
        let entry = AuditDraft {
            actor_device_id: Some(self.principal.device_id),
            actor_role: Some(&self.principal.role),
            source_route: "/authorization",
            action: self.capability.name(),
            resource: self.resource.as_deref(),
            result,
            operation_id: None,
            request_id: None,
            details,
        };
        match crate::audit::append(&conn, self.state.clock.as_ref(), &entry) {
            Ok(_) => Ok(()),
            Err(error) => {
                tracing::error!(%error, action = entry.action, "audit write failed");
                if self.capability.is_sensitive_mutation() {
                    Err(crate::audit::unavailable_envelope(error))
                } else {
                    Ok(())
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::AccessAuthentication;
    use crate::state::RuntimeConfig;
    use spark_core::identity::{FileIdentityStore, IdentityStore};

    fn state(directory: &std::path::Path) -> AppState {
        let identity = FileIdentityStore::new(directory.join("identity"))
            .load_or_create("authz-test")
            .unwrap();
        let mut connection = rusqlite::Connection::open_in_memory().unwrap();
        crate::migration::migrate(&mut connection).unwrap();
        AppState::new(
            RuntimeConfig {
                api_major: 1,
                runtime_version: "test".into(),
                listen: "127.0.0.1:0".parse().unwrap(),
                node_name: "authz-test".into(),
                data_dir: directory.to_path_buf(),
                advertise: false,
                tls: false,
            },
            identity,
            std::sync::Arc::new(spark_telemetry::FakeSystemMonitor),
            Some(connection),
        )
    }

    fn principal(state: &AppState, role: &str) -> Principal {
        let id = uuid::Uuid::new_v4();
        let conn = state.database.as_ref().unwrap().lock();
        crate::store::insert_device(
            &conn,
            &id,
            "test device",
            "macos",
            b"spki",
            &format!("fingerprint-{id}"),
            role,
        )
        .unwrap();
        Principal {
            device_id: id,
            role: role.into(),
            access_authentication: AccessAuthentication::DeviceSignature,
            user_presence: None,
        }
    }

    #[test]
    fn a_denied_action_is_audited_and_refused() {
        let directory = tempfile::tempdir().unwrap();
        let state = state(directory.path());
        let observer = principal(&state, "observer");

        let denial = state
            .require(&observer, Capability::ProjectCreate)
            .check()
            .unwrap_err();
        assert_eq!(denial.0, StatusCode::FORBIDDEN);
        assert_eq!(denial.1.0["error"]["code"], "ROLE_FORBIDDEN");

        let conn = state.database.as_ref().unwrap().lock();
        let (action, result): (String, String) = conn
            .query_row(
                "SELECT action, result FROM audit_records ORDER BY sequence DESC LIMIT 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(action, "project.create");
        assert_eq!(result, "refused");
    }

    #[test]
    fn an_allowed_action_is_audited_as_accepted() {
        let directory = tempfile::tempdir().unwrap();
        let state = state(directory.path());
        let owner = principal(&state, "owner");

        state
            .require(&owner, Capability::ProjectCreate)
            .resource("project/new")
            .check()
            .unwrap();

        let conn = state.database.as_ref().unwrap().lock();
        let (result, resource): (String, Option<String>) = conn
            .query_row(
                "SELECT result, resource FROM audit_records ORDER BY sequence DESC LIMIT 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(result, "accepted");
        assert_eq!(resource.as_deref(), Some("project/new"));
    }

    #[test]
    fn project_scope_uses_stored_membership() {
        let directory = tempfile::tempdir().unwrap();
        let state = state(directory.path());
        let developer = principal(&state, "developer");
        let project_id = uuid::Uuid::new_v4();
        {
            let conn = state.database.as_ref().unwrap().lock();
            crate::store::insert_project(
                &conn,
                &project_id,
                "atlas",
                &developer.device_id,
                &directory.path().join("atlas").display().to_string(),
                None,
            )
            .unwrap();
        }

        assert!(
            state
                .require(&developer, Capability::ProjectTerminal)
                .in_project(project_id)
                .check()
                .is_err(),
            "a project owner row is not membership"
        );

        {
            let conn = state.database.as_ref().unwrap().lock();
            crate::store::insert_project_member(&conn, &project_id, &developer.device_id, "write")
                .unwrap();
        }
        assert!(
            state
                .require(&developer, Capability::ProjectTerminal)
                .in_project(project_id)
                .check()
                .is_ok()
        );
    }

    #[test]
    fn elevated_actions_refuse_without_a_presence_proof() {
        let directory = tempfile::tempdir().unwrap();
        let state = state(directory.path());
        let owner = principal(&state, "owner");
        let denial = state
            .require(&owner, Capability::NetworkManage)
            .check()
            .unwrap_err();
        assert_eq!(denial.1.0["error"]["code"], "USER_PRESENCE_REQUIRED");
    }
}
