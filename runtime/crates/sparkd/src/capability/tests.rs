use super::*;

fn request(role: Role, capability: Capability) -> Request {
    Request {
        capability,
        scope: ResourceScope::Node,
        role,
        device_id: uuid::Uuid::nil(),
        project_permission: None,
        presence: Presence::Absent,
        policy: CapabilityPolicy::default(),
    }
}

#[test]
fn observer_reads_status_and_nothing_else() {
    assert!(evaluate(&request(Role::Observer, Capability::NodeRead)).is_ok());
    assert_eq!(
        evaluate(&request(Role::Observer, Capability::InferenceRun)),
        Err(DenyReason::RoleForbidden)
    );
    assert_eq!(
        evaluate(&request(Role::Observer, Capability::ProjectCreate)),
        Err(DenyReason::RoleForbidden)
    );
}

#[test]
fn unknown_roles_get_the_lowest_authority() {
    assert_eq!(Role::parse("root"), Role::Guest);
    assert_eq!(Role::parse(""), Role::Guest);
    assert_eq!(Role::parse("Owner"), Role::Guest);
    assert_eq!(Role::parse("observer"), Role::Observer);
}

/// BH-18 failure direction: an unrecognised role reaches exactly the guest allow-list and nothing else.
#[test]
fn an_unrecognised_role_reaches_only_what_a_guest_reaches() {
    let unknown = Role::parse("role-that-was-never-valid");
    for capability in [
        Capability::NodeRead,
        Capability::InferenceRun,
        Capability::SharedAccessReadOwn,
    ] {
        assert!(
            evaluate(&request(unknown, capability)).is_ok(),
            "{capability} is on the guest allow-list"
        );
    }
    for capability in [
        Capability::DiagnosticsRead,
        Capability::ProjectList,
        Capability::AutomationRead,
        Capability::TelemetryRead,
        Capability::DeviceRead,
        Capability::DevicePair,
        Capability::SharedAccessRead,
    ] {
        assert_eq!(
            evaluate(&request(unknown, capability)),
            Err(DenyReason::RoleForbidden),
            "{capability} must be refused to an unrecognised role"
        );
    }
}

/// BH-17: host telemetry is a capability, and it sits with the other host-scoped reads.
#[test]
fn reading_host_telemetry_is_administrator_or_owner() {
    for role in [Role::Guest, Role::Observer, Role::User, Role::Developer] {
        assert_eq!(
            evaluate(&request(role, Capability::TelemetryRead)),
            Err(DenyReason::RoleForbidden),
            "{role:?} must not read host telemetry"
        );
    }
    for role in [Role::Administrator, Role::Owner] {
        assert!(
            evaluate(&request(role, Capability::TelemetryRead)).is_ok(),
            "{role:?} reads host telemetry"
        );
    }
    // Reading it needs no presence, unlike taking a diagnostics bundle off the node.
    assert!(!crate::capability::requires_presence(
        Capability::TelemetryRead,
        &ResourceScope::Node
    ));
}

#[test]
fn project_capabilities_need_membership_even_for_the_owner() {
    let mut owner = request(Role::Owner, Capability::ProjectTerminal);
    owner.scope = ResourceScope::Project {
        project_id: uuid::Uuid::new_v4(),
    };
    assert_eq!(evaluate(&owner), Err(DenyReason::ProjectForbidden));

    owner.project_permission = Some(ProjectPermission::Read);
    assert_eq!(evaluate(&owner), Err(DenyReason::ProjectForbidden));

    owner.project_permission = Some(ProjectPermission::Write);
    assert!(evaluate(&owner).is_ok());
}

#[test]
fn approving_a_change_needs_the_approve_permission() {
    let mut caller = request(Role::Developer, Capability::AgentChangeApprove);
    caller.scope = ResourceScope::Project {
        project_id: uuid::Uuid::new_v4(),
    };
    caller.project_permission = Some(ProjectPermission::Write);
    assert_eq!(evaluate(&caller), Err(DenyReason::ProjectForbidden));
    caller.project_permission = Some(ProjectPermission::Approve);
    assert!(evaluate(&caller).is_ok());
}

#[test]
fn a_project_scoped_capability_is_never_satisfied_at_node_scope() {
    let mut caller = request(Role::Owner, Capability::ProjectFileWrite);
    caller.project_permission = Some(ProjectPermission::Admin);
    assert_eq!(evaluate(&caller), Err(DenyReason::ProjectForbidden));
}

#[test]
fn listing_projects_stays_available_to_ordinary_members() {
    // List at node scope but filter membership in the handler so members can discover their own projects.
    assert!(evaluate(&request(Role::User, Capability::ProjectList)).is_ok());
    assert!(evaluate(&request(Role::Developer, Capability::ProjectList)).is_ok());
    assert_eq!(
        evaluate(&request(Role::Observer, Capability::ProjectList)),
        Err(DenyReason::RoleForbidden)
    );
    // Reading a specific project still needs membership of that project.
    let mut member = request(Role::User, Capability::ProjectReadOwn);
    member.scope = ResourceScope::Project {
        project_id: uuid::Uuid::new_v4(),
    };
    assert_eq!(evaluate(&member), Err(DenyReason::ProjectForbidden));
    member.project_permission = Some(ProjectPermission::Read);
    assert!(evaluate(&member).is_ok());
}

#[test]
fn every_revocation_needs_presence_whatever_the_target() {
    // Every device revocation requires presence, regardless of the target's authority.
    for target in [
        Role::User,
        Role::Developer,
        Role::Administrator,
        Role::Owner,
    ] {
        let mut revoke = request(Role::Owner, Capability::DeviceRevoke);
        revoke.scope = ResourceScope::Device {
            target_role: target,
        };
        assert_eq!(
            evaluate(&revoke),
            Err(DenyReason::UserPresenceRequired),
            "revoking {target:?} must need presence"
        );
        revoke.presence = Presence::Fresh;
        assert!(
            evaluate(&revoke).is_ok(),
            "revoking {target:?} with presence"
        );
    }
}

#[test]
fn pairing_needs_presence_only_for_elevated_roles() {
    // Require presence for privileged invitations, while user and developer invitations remain ordinary administration.
    for target in [Role::User, Role::Developer] {
        let mut pair = request(Role::Owner, Capability::DevicePair);
        pair.scope = ResourceScope::Device {
            target_role: target,
        };
        assert!(evaluate(&pair).is_ok(), "inviting {target:?}");
    }
    for target in [Role::Administrator, Role::Owner] {
        let mut pair = request(Role::Owner, Capability::DevicePair);
        pair.scope = ResourceScope::Device {
            target_role: target,
        };
        assert_eq!(
            evaluate(&pair),
            Err(DenyReason::UserPresenceRequired),
            "inviting {target:?} must need presence"
        );
        pair.presence = Presence::Fresh;
        assert!(evaluate(&pair).is_ok());
    }
}

#[test]
fn device_management_respects_the_authority_ceiling() {
    let mut admin = request(Role::Administrator, Capability::DeviceRevoke);
    admin.presence = Presence::Fresh;
    admin.scope = ResourceScope::Device {
        target_role: Role::Owner,
    };
    assert_eq!(evaluate(&admin), Err(DenyReason::AuthorityCeiling));

    admin.scope = ResourceScope::Device {
        target_role: Role::Administrator,
    };
    assert_eq!(evaluate(&admin), Err(DenyReason::AuthorityCeiling));

    admin.scope = ResourceScope::Device {
        target_role: Role::Developer,
    };
    assert!(evaluate(&admin).is_ok());

    let mut owner = request(Role::Owner, Capability::DeviceRevoke);
    owner.presence = Presence::Fresh;
    owner.scope = ResourceScope::Device {
        target_role: Role::Owner,
    };
    assert!(evaluate(&owner).is_ok());
}

#[test]
fn elevated_actions_require_a_fresh_presence_proof() {
    for capability in [
        Capability::NetworkManage,
        Capability::RuntimeUpdate,
        Capability::PowerManage,
        Capability::ClusterManage,
        Capability::RemoteManage,
    ] {
        let mut owner = request(Role::Owner, capability);
        owner.scope = ResourceScope::Node;
        assert_eq!(
            evaluate(&owner),
            Err(DenyReason::UserPresenceRequired),
            "{capability} allowed without presence"
        );
        owner.presence = Presence::Fresh;
        assert!(
            evaluate(&owner).is_ok(),
            "{capability} denied with presence"
        );
    }
}

#[test]
fn node_scoped_diagnostics_are_administrator_only() {
    // Developer diagnostics permission does not grant access to host images or published ports.
    for role in [Role::Observer, Role::User, Role::Developer] {
        assert_eq!(
            evaluate(&request(role, Capability::DiagnosticsRead)),
            Err(DenyReason::RoleForbidden),
            "{role:?} must not read host diagnostics"
        );
    }
    for role in [Role::Administrator, Role::Owner] {
        assert!(
            evaluate(&request(role, Capability::DiagnosticsRead)).is_ok(),
            "{role:?} must read host diagnostics"
        );
    }
    // Project-scoped diagnostics keep the matrix's developer floor.
    let mut developer = request(Role::Developer, Capability::DiagnosticsRead);
    developer.scope = ResourceScope::Project {
        project_id: uuid::Uuid::new_v4(),
    };
    assert!(evaluate(&developer).is_ok());
}

#[test]
fn optional_policy_cells_default_closed() {
    assert_eq!(
        evaluate(&request(Role::Developer, Capability::ModelInstall)),
        Err(DenyReason::PolicyForbidden)
    );
    assert!(evaluate(&request(Role::Developer, Capability::ModelOperate)).is_ok());
    assert_eq!(
        evaluate(&request(Role::Administrator, Capability::RecipeImport)),
        Err(DenyReason::PolicyForbidden)
    );

    let mut permissive = request(Role::Developer, Capability::ModelInstall);
    permissive.policy.developer_model_install = true;
    assert!(evaluate(&permissive).is_ok());
}

#[test]
fn remote_management_is_owner_only_by_default() {
    let mut admin = request(Role::Administrator, Capability::RemoteManage);
    admin.presence = Presence::Fresh;
    assert_eq!(evaluate(&admin), Err(DenyReason::PolicyForbidden));
    admin.policy.administrator_remote_manage = true;
    assert!(evaluate(&admin).is_ok());

    let mut owner = request(Role::Owner, Capability::RemoteManage);
    owner.presence = Presence::Fresh;
    assert!(evaluate(&owner).is_ok());
}

#[test]
fn ownership_management_is_owner_only() {
    let mut admin = request(Role::Administrator, Capability::OwnershipManage);
    admin.presence = Presence::Fresh;
    assert_eq!(evaluate(&admin), Err(DenyReason::RoleForbidden));
}

#[test]
fn a_guest_holds_only_chat_node_read_and_its_own_shared_access_record() {
    assert!(evaluate(&request(Role::Guest, Capability::NodeRead)).is_ok());
    assert!(evaluate(&request(Role::Guest, Capability::InferenceRun)).is_ok());
    assert!(evaluate(&request(Role::Guest, Capability::SharedAccessReadOwn)).is_ok());
    for denied in [
        Capability::ModelInstall,
        Capability::ModelOperate,
        Capability::NetworkManage,
        Capability::RemoteManage,
        Capability::DevicePair,
        Capability::DeviceRevoke,
        Capability::DiagnosticsRead,
        Capability::ProjectList,
        Capability::ProjectCreate,
        Capability::AgentRun,
        Capability::BuildSubmit,
        Capability::CredentialManage,
        Capability::SharedAccessManage,
        Capability::SharedAccessRead,
        Capability::InferencePoolRoute,
    ] {
        assert_eq!(
            evaluate(&request(Role::Guest, denied)),
            Err(DenyReason::RoleForbidden),
            "a guest must not hold {denied}"
        );
    }
}

#[test]
fn unknown_roles_cannot_gain_authority_above_a_guest() {
    assert!(Role::Guest < Role::Observer);
    assert_eq!(Role::parse("guest"), Role::Guest);
    assert_eq!(Role::parse("Guest"), Role::Guest);
    assert_eq!(Role::Guest.name(), "guest");
}

#[test]
fn shared_access_management_is_owner_only_and_always_needs_presence() {
    assert!(crate::capability::requires_presence(
        Capability::SharedAccessManage,
        &ResourceScope::Node
    ));
    let mut administrator = request(Role::Administrator, Capability::SharedAccessManage);
    administrator.presence = Presence::Fresh;
    assert_eq!(evaluate(&administrator), Err(DenyReason::RoleForbidden));

    let owner = request(Role::Owner, Capability::SharedAccessManage);
    assert_eq!(evaluate(&owner), Err(DenyReason::UserPresenceRequired));

    let mut present = owner;
    present.presence = Presence::Fresh;
    assert!(evaluate(&present).is_ok());
}
