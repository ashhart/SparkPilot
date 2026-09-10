import Foundation
import Network
import SparkAPI
import SparkCore
import SparkDiscovery
import SparkLibrary
import Testing
@testable import SparkAppComposition

// MARK: - Fixtures

func compositionLibraryTestCompositionNodeID(_ hex: UInt64) -> SparkNodeID {
    SparkNodeID(rawValue: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", hex))!)
}

func compositionLibraryTestIdentityJSON(
    node: UInt64,
    cluster: UInt64? = nil,
    name: String = "My Spark",
    role: String = "standalone"
) -> String {
    let clusterValue =
        cluster.map { "\"\(compositionLibraryTestCompositionNodeID($0).rawValue.uuidString)\"" }
        ?? "null"
    return """
        {"node_id":"\(compositionLibraryTestCompositionNodeID(node).rawValue.uuidString)","cluster_id":\(clusterValue),"name":"\(name)","role":"\(role)","authority_fingerprint":"fp123","runtime_version":"0.1.0","dgx_os_version":null}
        """
}

func compositionLibraryTestDecodeIdentity(_ json: String) throws -> SparkIdentity {
    try JSONDecoder().decode(SparkIdentity.self, from: Data(json.utf8))
}

/// Construct authenticated identities only through testable module-internal APIs.
func compositionLibraryTestAuthenticated(_ json: String) throws -> AuthenticatedIdentity {
    AuthenticatedIdentity(identity: try compositionLibraryTestDecodeIdentity(json))
}

func compositionLibraryTestSeedTarget(node: UInt64, host: String) -> AuthenticatedTarget {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.port = 7443
    return AuthenticatedTarget(
        nodeID: compositionLibraryTestCompositionNodeID(node),
        clusterID: nil,
        name: "My Spark",
        role: .standalone,
        authorityFingerprint: "fp",
        displayName: host.replacingOccurrences(of: ".local", with: ""),
        routes: [CachedRoute(baseURL: components.url!, kind: .localWiFi)]
    )
}

/// Fake identity resolver for composition tests. Result is fixed per test.
actor CompositionLibraryTestFakeIdentityResolver: AuthenticatedIdentityResolving {
    private let result: Result<AuthenticatedIdentity, AuthenticatedIdentityError>

    init(_ result: Result<AuthenticatedIdentity, AuthenticatedIdentityError>) {
        self.result = result
    }

    func resolveIdentity(
        route: URL,
        expectedNodeID: SparkNodeID?
    ) async throws -> AuthenticatedIdentity {
        try result.get()
    }
}

actor CompositionLibraryTestRouteSensitiveIdentityResolver: AuthenticatedIdentityResolving {
    private let workingHost: String
    private let identity: AuthenticatedIdentity
    private var requestedHosts: [String] = []

    init(workingHost: String, identity: AuthenticatedIdentity) {
        self.workingHost = workingHost
        self.identity = identity
    }

    func resolveIdentity(
        route: URL,
        expectedNodeID: SparkNodeID?
    ) async throws -> AuthenticatedIdentity {
        requestedHosts.append(route.host ?? "")
        guard route.host?.caseInsensitiveCompare(workingHost) == .orderedSame else {
            throw AuthenticatedIdentityError.pinRejected
        }
        return identity
    }

    func hosts() -> [String] { requestedHosts }
}

struct CompositionLibraryTestStaticSavedSparkRouteDiscovery: SavedSparkRouteDiscovering {
    let routes: [URL]

    func candidateRoutes() async -> [URL] { routes }
}

actor CompositionLibraryTestActivationRuntime: SparkRuntimeReading {
    private var healthReads = 0

    func health(route: URL) async throws -> Health {
        healthReads += 1
        return try decode(
            """
            {"api_version":1,"node_id":"\(compositionLibraryTestCompositionNodeID(1).rawValue.uuidString)","runtime_version":"0.1.0","status":"ok"}
            """
        )
    }

    func status(route: URL) async throws -> SparkStatus {
        try decode(
            """
            {"api_version":1,"node":{"node_id":"\(compositionLibraryTestCompositionNodeID(1).rawValue.uuidString)","cluster_id":null,"name":"My Spark","role":"standalone","authority_fingerprint":"fp","runtime_version":"0.1.0","dgx_os_version":null},"cluster":null,"system":{"unified_memory_total_bytes":137438953472,"unified_memory_available_bytes":68719476736,"memory_pressure":"normal","cpu_utilisation":0.1,"disk_free_bytes":900000000000,"uptime_seconds":120,"temperature_celsius":48},"inference":{"state":"unloaded","model_id":null,"profile_id":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null}}
            """
        )
    }

    func models(route: URL) async throws -> ModelCatalogue {
        try decode(#"{"items":[],"next_cursor":null}"#)
    }

    func activeInference(route: URL) async throws -> ActiveInference {
        try decode(
            #"{"state":"unloaded","model_id":null,"profile_id":null,"context_length":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null}"#
        )
    }

    func healthReadCount() -> Int { healthReads }

    private func decode<Value: Decodable>(_ json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }
}

@MainActor
func compositionLibraryTestMakeModel(
    resolver: any AuthenticatedIdentityResolving
) throws -> RetailOnboardingModel {
    let store = try SwiftDataLibraryStore()
    return RetailOnboardingModel(
        library: SparkLibrary(store: store),
        identityResolver: resolver
    )
}

// MARK: - Dashboard publishing is gated on authentication

/// Delay identity resolution so tests can observe in-flight probe state.
actor CompositionLibraryTestDelayedIdentityResolver: AuthenticatedIdentityResolving {
    private let identity: AuthenticatedIdentity

    init(_ identity: AuthenticatedIdentity) {
        self.identity = identity
    }

    func resolveIdentity(route: URL, expectedNodeID: SparkNodeID?) async throws
        -> AuthenticatedIdentity
    {
        try await Task.sleep(for: .milliseconds(25))
        return identity
    }
}

actor CompositionLibraryTestGenericThrowingResolver: AuthenticatedIdentityResolving {
    func resolveIdentity(route: URL, expectedNodeID: SparkNodeID?) async throws
        -> AuthenticatedIdentity
    {
        throw URLError(.cannotConnectToHost)
    }
}

// MARK: - Probe lifecycle

/// Resolve by host with a controlled delay to test competing probes deterministically.
actor CompositionLibraryTestRouteKeyedIdentityResolver: AuthenticatedIdentityResolving {
    private let identities: [String: AuthenticatedIdentity]
    private let slowHost: String?
    private let delayMs: Int

    init(
        _ identities: [String: AuthenticatedIdentity],
        slowHost: String? = nil,
        delayMs: Int = 60
    ) {
        self.identities = identities
        self.slowHost = slowHost
        self.delayMs = delayMs
    }

    func resolveIdentity(
        route: URL,
        expectedNodeID: SparkNodeID?
    ) async throws -> AuthenticatedIdentity {
        if let slowHost, route.host == slowHost {
            try await Task.sleep(for: .milliseconds(delayMs))
        }
        guard let identity = identities[route.host ?? ""] else {
            throw URLError(.cannotFindHost)
        }
        return identity
    }
}

// MARK: - Probe cancellation

/// Ignores cooperative cancellation and returns URLError.cancelled to verify library state still remains unchanged.
actor CompositionLibraryTestCancelIgnoringURLErrorResolver: AuthenticatedIdentityResolving {
    func resolveIdentity(route: URL, expectedNodeID: SparkNodeID?) async throws
        -> AuthenticatedIdentity
    {
        do {
            try await Task.sleep(for: .milliseconds(80))
        } catch {
            // Ignore cooperative cancellation entirely.
        }
        throw URLError(.cancelled)
    }
}

actor CompositionLibraryTestRecoveringOpenResolver: AuthenticatedIdentityResolving {
    private var rejectsAuthentication = true
    private let identity: AuthenticatedIdentity

    init(identity: AuthenticatedIdentity) { self.identity = identity }
    func allowAuthentication() { rejectsAuthentication = false }
    func resolveIdentity(route: URL, expectedNodeID: SparkNodeID?) async throws
        -> AuthenticatedIdentity
    {
        if rejectsAuthentication {
            throw APIError(.reported, statusCode: 401, code: "AUTH_SIGNATURE_INVALID")
        }
        return identity
    }
}
