import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

// MARK: - Authenticated dashboard composition

actor DeviceManagementTestDeviceNavigationRuntime:
    SparkRuntimeReading, DeviceManagementProviding, RemoteAccessReading
{
    private let devicesByHost: [String: [GeneratedAPI.Device]]
    private var requestedRoutes: [URL] = []

    init(devicesByHost: [String: [GeneratedAPI.Device]] = [:]) {
        self.devicesByHost = devicesByHost
    }

    func health(route: URL) async throws -> Health { throw PendingRuntimeError.unconfigured }
    func status(route: URL) async throws -> SparkStatus { throw PendingRuntimeError.unconfigured }
    func models(route: URL) async throws -> ModelCatalogue {
        throw PendingRuntimeError.unconfigured
    }
    func activeInference(route: URL) async throws -> ActiveInference {
        throw PendingRuntimeError.unconfigured
    }

    func devices(route: URL) async throws -> [GeneratedAPI.Device] {
        requestedRoutes.append(route)
        return devicesByHost[route.host ?? ""] ?? []
    }

    func revokeDevice(
        route: URL,
        deviceID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws {}

    func remoteStatus(route: URL) async throws -> RemoteStatus {
        RemoteStatus(enabled: false, mode: .disabled, health: .disabled)
    }

    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    func disableRemote(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw PendingRuntimeError.unconfigured
    }

    func routes() -> [URL] { requestedRoutes }
}

actor DeviceManagementTestDeviceNavigationIdentityResolver: AuthenticatedIdentityResolving {
    private let identitiesByHost: [String: AuthenticatedIdentity]

    init(identitiesByHost: [String: AuthenticatedIdentity]) {
        self.identitiesByHost = identitiesByHost
    }

    func resolveIdentity(
        route: URL,
        expectedNodeID: SparkNodeID?
    ) async throws -> AuthenticatedIdentity {
        guard let identity = identitiesByHost[route.host ?? ""] else {
            throw AuthenticatedIdentityError.unbound
        }
        return identity
    }
}

func deviceManagementTestDeviceNavigationNodeID(_ suffix: UInt64) -> SparkNodeID {
    SparkNodeID(
        rawValue: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", suffix))!
    )
}

func deviceManagementTestDeviceNavigationIdentity(
    node: UInt64,
    name: String
) throws -> AuthenticatedIdentity {
    let nodeID = deviceManagementTestDeviceNavigationNodeID(node).rawValue.uuidString
    let json =
        """
        {"node_id":"\(nodeID)","cluster_id":null,"name":"\(name)","role":"standalone","authority_fingerprint":"authority","tls_fingerprint":null,"runtime_version":"0.1.0","dgx_os_version":null}
        """
    let identity = try JSONDecoder().decode(SparkIdentity.self, from: Data(json.utf8))
    return AuthenticatedIdentity(identity: identity)
}

func deviceManagementTestDeviceNavigationTarget(
    node: UInt64,
    host: String,
    name: String
) -> AuthenticatedTarget {
    AuthenticatedTarget(
        nodeID: deviceManagementTestDeviceNavigationNodeID(node),
        clusterID: nil,
        name: name,
        role: .standalone,
        authorityFingerprint: "authority",
        displayName: name,
        routes: [
            CachedRoute(
                baseURL: URL(string: "https://\(host):7443")!,
                kind: .localWiFi
            )
        ]
    )
}

func deviceManagementTestDeviceNavigationTrust(node: UInt64, name: String) -> NodeTrust {
    NodeTrust(
        nodeID: deviceManagementTestDeviceNavigationNodeID(node).rawValue.uuidString.lowercased(),
        nodeName: name,
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: String(repeating: "b", count: 64),
        authorityPublicKey: String(repeating: "c", count: 64),
        pairedAt: deviceManagementTestDeviceManagementDate
    )
}
