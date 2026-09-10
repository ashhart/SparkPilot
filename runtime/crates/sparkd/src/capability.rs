//! Evaluate role, stored resource scope, deployment policy, authority ceiling and presence; authz records the decision.

use std::fmt;

/// Name permissions explicitly so handlers authorize capabilities rather than inferring access from role strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Capability {
    NodeRead,
    InferenceRun,
    InferencePoolRoute,
    /// Permit node-scoped listing while filtering results to the caller's project memberships.
    ProjectList,
    ProjectReadOwn,
    ProjectCreate,
    ProjectDelete,
    ProjectFileRead,
    ProjectFileWrite,
    ProjectTerminal,
    ProjectPreview,
    AgentRun,
    AgentChangeRead,
    AgentChangeApprove,
    ModelInstall,
    ModelOperate,
    RecipeImport,
    DiagnosticsRead,
    /// Require elevated owner or administrator presence to export diagnostics off the node.
    DiagnosticsExport,
    /// Read this host's live instrumentation and its recorded history: thermals, power, memory, storage and the day's token totals.
    TelemetryRead,
    /// List the devices paired with this Spark, without the presence or authority ceiling a change to one needs.
    DeviceRead,
    NetworkManage,
    RemoteManage,
    /// Require fresh presence when an invitation grants administrator or owner authority.
    DevicePair,
    /// Require presence for every device revocation in addition to the target-authority ceiling.
    DeviceRevoke,
    RuntimeUpdate,
    PowerManage,
    ClusterManage,
    OwnershipManage,
    BuildWorkerRead,
    BuildWorkerRegister,
    BuildSubmit,
    BuildRead,
    BuildClaim,
    BuildReport,
    CredentialManage,
    /// Owner-only reading of the guest list, their policies and their usage.
    SharedAccessRead,
    /// Owner-only control of guest shared access: policies, activation, pause, revocation.
    SharedAccessManage,
    /// A guest reading its own policy and its own usage; never another device's.
    SharedAccessReadOwn,
    /// Read this Spark's automations and their run history.
    AutomationRead,
    /// Create, change, delete and trigger automations, and set what the model may reach on the internet.
    AutomationManage,
}

impl Capability {
    /// Stable machine name used in audit records and denial envelopes.
    pub fn name(self) -> &'static str {
        match self {
            Capability::NodeRead => "node.read",
            Capability::InferenceRun => "inference.run",
            Capability::InferencePoolRoute => "inference.pool.route",
            Capability::ProjectList => "project.list",
            Capability::ProjectReadOwn => "project.read",
            Capability::ProjectCreate => "project.create",
            Capability::ProjectDelete => "project.delete",
            Capability::ProjectFileRead => "project.file.read",
            Capability::ProjectFileWrite => "project.file.write",
            Capability::ProjectTerminal => "project.terminal",
            Capability::ProjectPreview => "project.preview",
            Capability::AgentRun => "agent.run",
            Capability::AgentChangeRead => "agent.change.read",
            Capability::AgentChangeApprove => "agent.change.approve",
            Capability::ModelInstall => "model.install",
            Capability::ModelOperate => "model.operate",
            Capability::RecipeImport => "recipe.import",
            Capability::DiagnosticsRead => "diagnostics.read",
            Capability::DiagnosticsExport => "diagnostics.export",
            Capability::TelemetryRead => "telemetry.read",
            Capability::DeviceRead => "device.read",
            Capability::NetworkManage => "network.manage",
            Capability::RemoteManage => "remote.manage",
            Capability::DevicePair => "device.pair",
            Capability::DeviceRevoke => "device.revoke",
            Capability::RuntimeUpdate => "runtime.update",
            Capability::PowerManage => "power.manage",
            Capability::ClusterManage => "cluster.manage",
            Capability::OwnershipManage => "ownership.manage",
            Capability::BuildWorkerRead => "build.worker.read",
            Capability::BuildWorkerRegister => "build.worker.register",
            Capability::BuildSubmit => "build.submit",
            Capability::BuildRead => "build.read",
            Capability::BuildClaim => "build.claim",
            Capability::BuildReport => "build.report",
            Capability::CredentialManage => "credential.manage",
            Capability::SharedAccessRead => "shared_access.read",
            Capability::SharedAccessManage => "shared_access.manage",
            Capability::SharedAccessReadOwn => "shared_access.read_own",
            Capability::AutomationRead => "automation.read",
            Capability::AutomationManage => "automation.manage",
        }
    }

    /// Identify decisions whose audit records are required even when authorization is denied.
    pub fn is_sensitive_mutation(self) -> bool {
        matches!(
            self,
            Capability::ProjectCreate
                | Capability::ProjectDelete
                | Capability::ProjectFileWrite
                | Capability::ProjectTerminal
                | Capability::AgentRun
                | Capability::AgentChangeApprove
                | Capability::ModelInstall
                | Capability::ModelOperate
                | Capability::RecipeImport
                // Fail export if auditing fails so no support bundle leaves the node unrecorded.
                | Capability::DiagnosticsExport
                | Capability::NetworkManage
                | Capability::RemoteManage
                | Capability::DevicePair
                | Capability::DeviceRevoke
                | Capability::RuntimeUpdate
                | Capability::PowerManage
                | Capability::ClusterManage
                | Capability::OwnershipManage
                | Capability::BuildWorkerRegister
                | Capability::BuildSubmit
                | Capability::BuildClaim
                | Capability::BuildReport
                | Capability::CredentialManage
                | Capability::SharedAccessManage
                | Capability::AutomationManage
        )
    }
}

impl fmt::Display for Capability {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.name())
    }
}

/// Device roles ordered by authority.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Role {
    /// A friend's device borrowing the owner's Spark under a per-guest policy; the lowest authority on the node.
    Guest,
    PoolRouter,
    Observer,
    User,
    Developer,
    Administrator,
    Owner,
}

impl Role {
    /// Parse an unknown stored role as `Guest`, the lowest authority in the `Ord`, so a corrupt role can only narrow reach.
    pub fn parse(value: &str) -> Role {
        match value {
            "pool_router" => Role::PoolRouter,
            "guest" => Role::Guest,
            "owner" => Role::Owner,
            "administrator" => Role::Administrator,
            "developer" => Role::Developer,
            "user" => Role::User,
            "observer" => Role::Observer,
            _ => Role::Guest,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Role::PoolRouter => "pool_router",
            Role::Guest => "guest",
            Role::Observer => "observer",
            Role::User => "user",
            Role::Developer => "developer",
            Role::Administrator => "administrator",
            Role::Owner => "owner",
        }
    }
}

/// A device's permission inside one project (`project_members.permission`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ProjectPermission {
    Read,
    Write,
    Approve,
    Admin,
}

impl ProjectPermission {
    pub fn parse(value: &str) -> Option<ProjectPermission> {
        match value {
            "read" => Some(ProjectPermission::Read),
            "write" => Some(ProjectPermission::Write),
            "approve" => Some(ProjectPermission::Approve),
            "admin" => Some(ProjectPermission::Admin),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            ProjectPermission::Read => "read",
            ProjectPermission::Write => "write",
            ProjectPermission::Approve => "approve",
            ProjectPermission::Admin => "admin",
        }
    }
}

/// Require membership of the specific project in addition to role permission.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResourceScope {
    /// The node itself (status, models, network, updates, devices).
    Node,
    /// Scope to the resource's stored project identity, never its URL alone.
    Project { project_id: uuid::Uuid },
    /// Target identity subject to the actor's authority ceiling.
    Device { target_role: Role },
    /// A build job owned by one project and requested by one device.
    Build {
        project_id: uuid::Uuid,
        requested_by: uuid::Uuid,
    },
}

/// Control optional or conditional capabilities through deployment policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CapabilityPolicy {
    /// Permit model loading for developers by default.
    pub developer_model_operate: bool,
    /// Require explicit policy to permit developer installs.
    pub developer_model_install: bool,
    /// Keep unverified imports behind an explicit runtime flag.
    pub administrator_recipe_import: bool,
    /// Deny administrator remote management by default, retaining owner control of remote exposure.
    pub administrator_remote_manage: bool,
}

impl Default for CapabilityPolicy {
    fn default() -> Self {
        Self {
            developer_model_operate: true,
            developer_model_install: false,
            administrator_recipe_import: false,
            administrator_remote_manage: false,
        }
    }
}

/// A verified fresh user-presence proof, or the absence of one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Presence {
    /// Proof already verified and consumed for this request.
    Fresh,
    /// No proof was presented, or it did not verify.
    Absent,
}

/// Authorization failure with a stable API error code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DenyReason {
    /// The role does not hold the capability at all.
    RoleForbidden,
    /// Project membership is missing or insufficient for the otherwise permitted capability.
    ProjectForbidden,
    /// Deployment policy withholds an optional capability from this role.
    PolicyForbidden,
    /// The target identity's authority is not below the actor's.
    AuthorityCeiling,
    /// A fresh user-presence proof is required and was not presented.
    UserPresenceRequired,
}

impl DenyReason {
    pub fn code(self) -> &'static str {
        match self {
            DenyReason::RoleForbidden | DenyReason::PolicyForbidden => "ROLE_FORBIDDEN",
            DenyReason::ProjectForbidden => "PROJECT_FORBIDDEN",
            DenyReason::AuthorityCeiling => "ROLE_FORBIDDEN",
            DenyReason::UserPresenceRequired => "USER_PRESENCE_REQUIRED",
        }
    }

    pub fn message(self) -> &'static str {
        match self {
            DenyReason::RoleForbidden => "this role does not hold the required capability",
            DenyReason::PolicyForbidden => "deployment policy withholds this capability",
            DenyReason::ProjectForbidden => "the device is not a member of this project",
            DenyReason::AuthorityCeiling => {
                "the target identity is not below this device's authority"
            }
            DenyReason::UserPresenceRequired => "this action requires a fresh user-presence proof",
        }
    }
}

/// Supply resolved membership and presence before evaluation so authorization remains free of I/O.
#[derive(Debug, Clone)]
pub struct Request {
    pub capability: Capability,
    pub scope: ResourceScope,
    pub role: Role,
    /// The actor's device id. Used for owner-of-resource checks.
    pub device_id: uuid::Uuid,
    /// Permission in the scoped project; None means no membership.
    pub project_permission: Option<ProjectPermission>,
    pub presence: Presence,
    pub policy: CapabilityPolicy,
}

/// Capabilities requiring fresh presence regardless of target authority.
fn always_requires_presence(capability: Capability) -> bool {
    matches!(
        capability,
        Capability::DiagnosticsExport
            | Capability::NetworkManage
            | Capability::RemoteManage
            // Require fresh presence for revocation even when the target has lower authority.
            | Capability::DeviceRevoke
            | Capability::RuntimeUpdate
            | Capability::PowerManage
            | Capability::ClusterManage
            | Capability::OwnershipManage
            // Editing, pausing or revoking a guest's access is an elevated owner action like the other device controls.
            | Capability::SharedAccessManage
    )
}

/// Combine always-elevated actions with invitations that grant administrator or owner authority.
pub fn requires_presence(capability: Capability, scope: &ResourceScope) -> bool {
    if always_requires_presence(capability) {
        return true;
    }
    matches!(
        (capability, scope),
        (
            Capability::DevicePair,
            ResourceScope::Device {
                target_role: Role::Administrator | Role::Owner
            }
        )
    )
}

/// The minimum project permission a project-scoped capability needs.
fn project_requirement(capability: Capability) -> Option<ProjectPermission> {
    Some(match capability {
        Capability::ProjectReadOwn
        | Capability::ProjectFileRead
        | Capability::ProjectPreview
        | Capability::AgentChangeRead
        | Capability::BuildRead => ProjectPermission::Read,
        Capability::ProjectFileWrite
        | Capability::ProjectTerminal
        | Capability::AgentRun
        | Capability::BuildSubmit => ProjectPermission::Write,
        Capability::AgentChangeApprove => ProjectPermission::Approve,
        Capability::ProjectDelete => ProjectPermission::Admin,
        _ => return None,
    })
}

/// Does the role hold the capability by default (before policy and scope)?
fn role_grants(
    role: Role,
    capability: Capability,
    policy: CapabilityPolicy,
) -> Result<(), DenyReason> {
    use Capability::*;
    use Role::*;

    if role == PoolRouter {
        return if capability == InferencePoolRoute {
            Ok(())
        } else {
            Err(DenyReason::RoleForbidden)
        };
    }
    // Allow-list the guest role so every capability added later is denied to guests until someone decides otherwise.
    if role == Guest {
        return if matches!(capability, NodeRead | InferenceRun | SharedAccessReadOwn) {
            Ok(())
        } else {
            Err(DenyReason::RoleForbidden)
        };
    }
    let minimum = match capability {
        NodeRead => Observer,
        SharedAccessReadOwn => Observer,
        SharedAccessRead | SharedAccessManage => Owner,
        DiagnosticsRead => Developer,
        // Node support bundles require owner or administrator authority; they are not project-scoped exports.
        DiagnosticsExport => Administrator,
        // Live host instrumentation is the same class of reading as a node diagnostic, so it sits at the same height.
        TelemetryRead | DeviceRead => Administrator,
        InferenceRun | InferencePoolRoute | ProjectList | ProjectReadOwn | ProjectFileRead
        | ProjectPreview | AgentChangeRead | BuildRead | BuildWorkerRead | AutomationRead => User,
        ProjectCreate | ProjectDelete | ProjectFileWrite | ProjectTerminal | AgentRun
        | AgentChangeApprove | BuildSubmit | BuildWorkerRegister | BuildClaim | BuildReport => {
            Developer
        }
        ModelInstall => {
            if role == Developer && !policy.developer_model_install {
                return Err(DenyReason::PolicyForbidden);
            }
            Developer
        }
        ModelOperate => {
            if role == Developer && !policy.developer_model_operate {
                return Err(DenyReason::PolicyForbidden);
            }
            Developer
        }
        RecipeImport => {
            if role == Administrator && !policy.administrator_recipe_import {
                return Err(DenyReason::PolicyForbidden);
            }
            Administrator
        }
        RemoteManage => {
            if role == Administrator && !policy.administrator_remote_manage {
                return Err(DenyReason::PolicyForbidden);
            }
            Administrator
        }
        NetworkManage | DevicePair | DeviceRevoke | RuntimeUpdate | PowerManage | ClusterManage
        | CredentialManage | AutomationManage => Administrator,
        OwnershipManage => Owner,
    };

    if role >= minimum {
        Ok(())
    } else {
        Err(DenyReason::RoleForbidden)
    }
}

/// Evaluate one authorisation request. Pure: no database, no clock.
pub fn evaluate(request: &Request) -> Result<(), DenyReason> {
    role_grants(request.role, request.capability, request.policy)?;

    if let Some(minimum) = project_requirement(request.capability) {
        // A project-scoped capability must be exercised against a project.
        let (ResourceScope::Project { .. } | ResourceScope::Build { .. }) = request.scope else {
            return Err(DenyReason::ProjectForbidden);
        };
        // A higher role never substitutes for membership in the scoped project.
        match request.project_permission {
            Some(held) if held >= minimum => {}
            _ => return Err(DenyReason::ProjectForbidden),
        }
    }

    // Require administrator authority for host diagnostics; developer access applies only inside authorized projects.
    if request.capability == Capability::DiagnosticsRead
        && request.scope == ResourceScope::Node
        && request.role < Role::Administrator
    {
        return Err(DenyReason::RoleForbidden);
    }

    if let ResourceScope::Device { target_role } = request.scope {
        // Administrators may manage only lower-authority identities; managing owners requires owner authority.
        if request.role != Role::Owner && target_role >= request.role {
            return Err(DenyReason::AuthorityCeiling);
        }
    }

    if requires_presence(request.capability, &request.scope) && request.presence != Presence::Fresh
    {
        return Err(DenyReason::UserPresenceRequired);
    }

    Ok(())
}

#[cfg(test)]
#[path = "capability/tests.rs"]
mod tests;
