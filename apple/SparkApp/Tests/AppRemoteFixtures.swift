import CryptoKit
import Foundation
import Network
import SparkAPI
import SparkAppComposition
import SparkDiscovery
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing

// MARK: - Remote settings model

enum AppShellTestFakeRemoteDisableFailure: Sendable {
    case network
    case presenceNotRegistered
    case rejected
}

struct AppShellTestFakeRemoteUnreachable: Error {}

@MainActor
final class AppShellTestTestRemoteRouteRegistration: RemoteAccessRouteRegistering {
    private(set) var registeredHosts: [String] = []
    private(set) var unregisterCount = 0
    var registrationError: (any Error)?

    func registerPrivateOverlay(hostname: String, basedOn currentRoute: URL) async throws {
        if let registrationError { throw registrationError }
        registeredHosts.append(hostname)
    }

    func unregisterPrivateOverlay(currentRoute: URL) {
        unregisterCount += 1
    }
}

@MainActor
extension RemoteAccessModel {
    convenience init(
        route: URL,
        runtime: any RemoteAccessReading,
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer(),
        maximumOperationPolls: Int = 300,
        operationDelay: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.init(
            route: route,
            runtime: runtime,
            routeRegistration: AppShellTestTestRemoteRouteRegistration(),
            userPresenceAuthorizer: userPresenceAuthorizer,
            maximumOperationPolls: maximumOperationPolls,
            operationDelay: operationDelay
        )
    }
}

func appShellTestRemoteAccessPreview(
    action: String,
    hostname: String? = "100.96.4.2",
    blockers: String = "[]"
) -> GeneratedAPI.ModelActionPreview {
    let hostnameJSON = hostname.map { "\"\($0)\"" } ?? "null"
    let json = """
        {
          "preview_digest":"\(String(repeating: "a", count: 64))","action":"\(action)",
          "target":{"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","cluster_id":null},"recipe":null,
          "evidence":{"remote":{"mode":"disabled","health":"disabled",
            "hostname":\(hostnameJSON),"requested_mode_available":true,"provider":"tailscale"},
            "active_inference_available":false,"engine_transitioning":false,
            "cluster_membership_available":false,"cluster_membership_source":null,"cluster":null},
          "evidence_timestamps":{"system_observed_at":"2026-08-31T12:00:00Z"},
          "consequences":{"model_to_stop":null,"profile_to_stop":null,
            "route_withdrawal":\(action == "remote.disable"),"service_interruption":"none",
            "files_removed":[],"reinstall_required":false},
          "blockers":\(blockers),"warnings":[{"code":"LOCAL_ONLY",
            "owner_explanation":"Local pairing stays available.","recovery_action":null}],
          "issued_at":"2026-08-31T12:00:00Z","expires_at":"2026-08-31T12:05:00Z"
        }
        """
    return try! JSONDecoder().decode(
        GeneratedAPI.ModelActionPreview.self,
        from: Data(json.utf8)
    )
}

actor AppShellTestFakeRemote: RemoteAccessReading, DeviceManagementProviding {
    private var status: RemoteStatus
    private var refreshedStatus: RemoteStatus?
    private var failures: [AppShellTestFakeRemoteDisableFailure]
    private var operationStates: [SparkAPI.Operation.OperationState]
    private var disableKeys: [UUID] = []
    private var enableKeys: [UUID] = []
    private var enrollmentKeys: [UUID] = []
    private var operationReadCount = 0
    private var suspendsDisable: Bool
    private var disableWasSubmitted = false
    private var disableContinuation: CheckedContinuation<Void, Never>?

    /// Represent complete Spark read failure without inventing remote-access state.
    private var statusIsUnreadable = false

    init(
        status: RemoteStatus,
        refreshedStatus: RemoteStatus? = nil,
        failures: [AppShellTestFakeRemoteDisableFailure] = [],
        operationStates: [SparkAPI.Operation.OperationState] = [],
        suspendsDisable: Bool = false,
        statusIsUnreadable: Bool = false
    ) {
        self.statusIsUnreadable = statusIsUnreadable
        self.status = status
        self.refreshedStatus = refreshedStatus
        self.failures = failures
        self.operationStates = operationStates
        self.suspendsDisable = suspendsDisable
    }

    func remoteStatus(route: URL) async throws -> RemoteStatus {
        if statusIsUnreadable { throw AppShellTestFakeRemoteUnreachable() }
        return status
    }

    func refreshRemoteHealth(route: URL) async throws -> RemoteStatus {
        if statusIsUnreadable { throw AppShellTestFakeRemoteUnreachable() }
        if let refreshedStatus { status = refreshedStatus }
        return status
    }

    func previewRemoteEnable(
        route: URL,
        body: RemotePreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        appShellTestRemoteAccessPreview(action: "remote.enable")
    }

    func enableRemote(
        route: URL,
        body: EnableRemoteRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        enableKeys.append(idempotencyKey)
        let state = operationStates.isEmpty ? .succeeded : operationStates.removeFirst()
        if state == .succeeded {
            status = RemoteStatus(
                enabled: true,
                mode: .privateOverlay,
                health: .healthy,
                hostname: "100.96.4.2",
                availableModes: [.privateOverlay],
                privateOverlayProvider: "tailscale"
            )
        }
        return try operation(state: state)
    }

    func previewRemoteDisable(
        route: URL,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        appShellTestRemoteAccessPreview(action: "remote.disable")
    }

    func disableRemote(
        route: URL,
        acceptedPreviewDigest: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        disableKeys.append(idempotencyKey)
        disableWasSubmitted = true
        if suspendsDisable {
            await withCheckedContinuation { continuation in
                disableContinuation = continuation
            }
        }
        if !failures.isEmpty {
            switch failures.removeFirst() {
            case .network:
                throw URLError(.networkConnectionLost)
            case .presenceNotRegistered:
                throw APIError(
                    .local(message: "Presence key is not registered."),
                    statusCode: 403,
                    code: "USER_PRESENCE_NOT_REGISTERED"
                )
            case .rejected:
                throw APIError(
                    .local(message: "The owner grant is required."),
                    statusCode: 403,
                    code: "OWNER_REQUIRED"
                )
            }
        }
        let state = operationStates.isEmpty ? .succeeded : operationStates.removeFirst()
        if state == .succeeded {
            status = RemoteStatus(enabled: false, mode: .disabled, health: .disabled)
        }
        return try operation(state: state)
    }

    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
        operationReadCount += 1
        let state = operationStates.isEmpty ? .succeeded : operationStates.removeFirst()
        if state == .succeeded {
            status = RemoteStatus(enabled: false, mode: .disabled, health: .disabled)
        }
        return try operation(state: state)
    }

    private func operation(state: SparkAPI.Operation.OperationState) throws -> SparkAPI.Operation {
        try appShellTestDecode(
            "{\"id\":\"63e82da2-7fb7-4b4b-9584-4a528000ac94\","
                + "\"kind\":\"remote.disable\",\"state\":\"\(state.rawValue)\","
                + "\"cancellable\":false}"
        )
    }

    func recordedDisableKeys() -> [UUID] { disableKeys }
    func recordedEnableKeys() -> [UUID] { enableKeys }
    func setStatusUnreadable(_ unreadable: Bool) { statusIsUnreadable = unreadable }

    func waitForDisableSubmission() async {
        while !disableWasSubmitted { await Task.yield() }
    }

    func resumeDisable() {
        suspendsDisable = false
        disableContinuation?.resume()
        disableContinuation = nil
    }

    func devices(route: URL) async throws -> [GeneratedAPI.Device] { [] }

    func revokeDevice(
        route: URL,
        deviceID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws {}

    func enrollPresenceKey(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> String {
        enrollmentKeys.append(idempotencyKey)
        return try userPresence.keyInfo.pairingFingerprint()
    }

    func recordedEnrollmentKeys() -> [UUID] { enrollmentKeys }
    func recordedOperationReadCount() -> Int { operationReadCount }
}
