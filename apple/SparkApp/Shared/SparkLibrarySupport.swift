import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity

// MARK: - Store location and app default

public enum SparkLibraryLocations {
    /// Versions the unreleased library store filename to avoid opening incompatible development schemas.
    public static let storeFileName = "library-2.store"

    /// Stores non-secret library metadata in local Application Support without iCloud or CloudKit.
    public static func defaultStoreURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("SparkFabric", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(storeFileName)
    }
}

extension SparkLibrary {
    /// Fall back to a session-only library and retain the real failure when durable SwiftData storage cannot open.
    public static func appLibrary() -> SparkLibrary {
        #if DEBUG
            // A debug build launched with --spark-sample-fleet runs on a pretend fleet instead.
            if let sample = FleetSampleFleet.sharedLibrary() { return sample }
        #endif
        do {
            return SparkLibrary(store: try SparkLibraryStoreFactory.makeDurableStore())
        } catch {
            return SparkLibrary(
                store: MemoryLibraryStore(),
                storageStatusOverride: "\(error)"
            )
        }
    }
}

/// Propagate durable-store failures so the UI can show session-only recovery.
public enum SparkLibraryStoreFactory {
    @MainActor
    public static func makeDurableStore() throws -> any SparkLibraryStoring {
        try SwiftDataLibraryStore(url: SparkLibraryLocations.defaultStoreURL())
    }
}

// MARK: - Node trust lookup

/// Looks up previously paired node trust in the Keychain; an absent record does not establish or revoke trust.
public enum StoredNodeTrust {
    public static let reader: @Sendable (String) -> NodeTrust? = { nodeID in
        try? NodeTrustStore().trust(forNode: nodeID)
    }
}

// MARK: - Authenticated identity resolver (injection point)

/// Restricts authenticated-identity construction to transport-verifying implementations in this module.
public struct AuthenticatedIdentity: Sendable, Equatable {
    public let identity: SparkIdentity

    /// Retain the verified transport so a cold remote-only launch can open its dashboard.
    let client: SparkAPIClient?

    init(identity: SparkIdentity, client: SparkAPIClient? = nil) {
        self.identity = identity
        self.client = client
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }

    public var nodeID: SparkNodeID { identity.nodeID }
}

/// Resolves full node identity through the paired TLS pin; discovery metadata and setup completion cannot authenticate a route.
public protocol AuthenticatedIdentityResolving: Sendable {
    /// Resolves the route against the expected paired node or throws AuthenticatedIdentityError without returning unverified identity.
    func resolveIdentity(
        route: URL,
        expectedNodeID: SparkNodeID?
    ) async throws -> AuthenticatedIdentity
}

/// Describes authentication outcomes from an explicit saved-Spark opening attempt, independently of background probes.
public struct SavedSparkOpenFailure: Equatable, Sendable {
    public enum Reason: Int, Equatable, Sendable {
        case unavailable
        case secureConnectionUnavailable
        case authentication
        case certificateRejected
        case identityMismatch
        case noRoute
        /// The node answered but speaks a signing protocol this build cannot.
        case protocolMismatch

        public var message: String {
            switch self {
            case .unavailable:
                String(
                    localized:
                        "Couldn’t reach this Spark. Check that it is powered on and reachable from this device, then try again."
                )
            case .secureConnectionUnavailable:
                String(
                    localized:
                        "A secure connection is unavailable. Check this device’s saved pairing and app setup, then try again."
                )
            case .authentication:
                String(
                    localized:
                        "This Spark did not accept this device’s authentication. Check your pairing and that the app and Spark runtime are compatible, then try again."
                )
            case .protocolMismatch:
                String(
                    localized:
                        "This Spark’s runtime and this app use different sign-in protocols. Update the Spark runtime from a device that still connects, or install the app version that matches the runtime."
                )
            case .certificateRejected:
                String(
                    localized:
                        "This Spark’s certificate does not match its saved identity. Check the Spark’s address and pairing before trying again."
                )
            case .identityMismatch:
                String(
                    localized:
                        "This address answered with a different Spark identity. Check the address and pair the intended Spark again if needed."
                )
            case .noRoute:
                String(
                    localized:
                        "This Spark has no saved connection address. Add it again to restore its connection."
                )
            }
        }
    }

    public let entryID: String
    public let reason: Reason
    public var canRetry: Bool { reason != .identityMismatch && reason != .noRoute }
}

public enum AuthenticatedIdentityError: Error, Sendable, Equatable {
    /// Refuse identity authentication when the target has no pairing pin or usable pinned transport.
    case unbound
    /// Represent failure to verify the paired TLS endpoint.
    case pinRejected
    /// Reject an authenticated TLS endpoint whose full node ID differs from stored trust.
    case nodeMismatch(presented: SparkNodeID)
}

/// Fails closed without a pinned transport while preserving cached cards and allowing setup to remain actionable.
public struct DeferredPinnedIdentityResolver: AuthenticatedIdentityResolving {
    public init() {}

    public func resolveIdentity(
        route: URL,
        expectedNodeID: SparkNodeID?
    ) async throws -> AuthenticatedIdentity {
        throw AuthenticatedIdentityError.unbound
    }
}

// MARK: - Card presentation

/// Plain-language presentation of a library card's connection state.
struct LibraryConnectionPresentation: Equatable, Sendable {
    let label: String
    let symbol: String
    let isOnline: Bool
    /// The path in use while online, so the card can say "Over Tailscale" and name the host.
    var path: SparkConnectionPath? = nil

    static func resolve(_ entry: LibraryEntry) -> LibraryConnectionPresentation {
        var presentation = resolve(entry.connectionState)
        if presentation.isOnline {
            presentation.path = SparkConnectionPath.resolve(entry: entry, activeRouteURL: nil)
        }
        return presentation
    }

    static func resolve(_ state: SparkConnectionState) -> LibraryConnectionPresentation {
        switch state {
        case .connectedDirect:
            return LibraryConnectionPresentation(
                label: String(localized: "Direct 10 GbE"),
                symbol: "cable.connector",
                isOnline: true
            )
        case .connectedWiFi:
            return LibraryConnectionPresentation(
                label: String(localized: "Local Wi-Fi"),
                symbol: "wifi",
                isOnline: true
            )
        case .connectedRemote:
            return LibraryConnectionPresentation(
                label: String(localized: "Remote"),
                symbol: "globe",
                isOnline: true
            )
        case .connecting:
            return LibraryConnectionPresentation(
                label: String(localized: "Connecting"),
                symbol: "hourglass",
                isOnline: false
            )
        case .discovering:
            return LibraryConnectionPresentation(
                label: String(localized: "Looking for Spark"),
                symbol: "antenna.radiowaves.left.and.right",
                isOnline: false
            )
        case .foundUnpaired:
            return LibraryConnectionPresentation(
                label: String(localized: "Not paired"),
                symbol: "person.badge.key",
                isOnline: false
            )
        case .offlineCached:
            return LibraryConnectionPresentation(
                label: String(localized: "Offline · cached"),
                symbol: "pause.circle",
                isOnline: false
            )
        case .identityMismatch:
            return LibraryConnectionPresentation(
                label: String(localized: "Identity changed"),
                symbol: "exclamationmark.triangle.fill",
                isOnline: false
            )
        case .updateRequired:
            return LibraryConnectionPresentation(
                label: String(localized: "Update required"),
                symbol: "arrow.down.circle",
                isOnline: false
            )
        }
    }
}

/// App-level route building from a host, matching the onboarding flow.
public enum SparkAppRoute {
    public static func localRoute(host: String, port: Int = 7443) -> URL? {
        var normalised = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalised.hasSuffix(".") {
            normalised.removeLast()
        }
        if normalised.lowercased().hasSuffix(".local") {
            normalised.removeLast(".local".count)
        }
        guard !normalised.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(normalised).local"
        components.port = port
        return components.url
    }
}

enum PrivateOverlayRouteRegistrationError: Error {
    case targetUnavailable
    case invalidTailscaleAddress
    case identityMismatch
}

/// Register reviewed remote routes only after pinned identity verification, keeping Tailscale installation and membership external.
@MainActor
final class LibraryRemoteAccessRouteRegistration: RemoteAccessRouteRegistering {
    private let library: SparkLibrary
    private let identityResolver: any AuthenticatedIdentityResolving
    private let targetID: String

    init(
        library: SparkLibrary,
        identityResolver: any AuthenticatedIdentityResolving,
        targetID: String
    ) {
        self.library = library
        self.identityResolver = identityResolver
        self.targetID = targetID
    }

    func rememberPrivateOverlay(hostname: String, basedOn currentRoute: URL) {
        guard
            Self.isTailscaleIPv4(hostname) || SparkConnectionPath.isTailscaleIPv6(hostname)
                || Self.isTailscaleName(hostname),
            currentRoute.scheme == "https",
            let entry = library.entry(id: targetID), let nodeID = entry.coordinatorNodeID
        else { return }
        var components = URLComponents()
        components.scheme = "https"
        components.host =
            SparkConnectionPath.isTailscaleIPv6(hostname) && !hostname.hasPrefix("[")
            ? "[\(hostname)]" : hostname
        components.port = currentRoute.port ?? 7443
        guard let url = components.url else { return }
        library.rememberRouteCandidate(
            entryID: targetID,
            nodeID: nodeID,
            route: CachedRoute(
                slotID: Self.overlaySlot(hostname),
                baseURL: url,
                kind: .privateOverlay,
                interfaceName: "tailscale"
            )
        )
    }

    func registerPrivateOverlay(hostname: String, basedOn currentRoute: URL) async throws {
        guard
            Self.isTailscaleIPv4(hostname) || SparkConnectionPath.isTailscaleIPv6(hostname)
                || Self.isTailscaleName(hostname)
        else {
            throw PrivateOverlayRouteRegistrationError.invalidTailscaleAddress
        }
        guard let entry = library.entry(id: targetID),
            let nodeID = entry.coordinatorNodeID,
            let member = entry.member(nodeID: nodeID)
        else {
            throw PrivateOverlayRouteRegistrationError.targetUnavailable
        }

        var components = URLComponents()
        components.scheme = currentRoute.scheme ?? "https"
        components.host =
            SparkConnectionPath.isTailscaleIPv6(hostname) && !hostname.hasPrefix("[")
            ? "[\(hostname)]" : hostname
        components.port = currentRoute.port ?? 7443
        guard let remoteRoute = components.url else {
            throw PrivateOverlayRouteRegistrationError.invalidTailscaleAddress
        }
        let authenticated = try await identityResolver.resolveIdentity(
            route: remoteRoute,
            expectedNodeID: nodeID
        )
        guard authenticated.nodeID == nodeID else {
            throw PrivateOverlayRouteRegistrationError.identityMismatch
        }

        library.markReachable(
            entryID: targetID,
            nodeID: nodeID,
            route: CachedRoute(
                slotID: Self.overlaySlot(hostname),
                baseURL: remoteRoute,
                kind: .privateOverlay,
                interfaceName: "tailscale",
                peerFingerprint: member.routes.compactMap(\.peerFingerprint).first
            )
        )
    }

    private static func overlaySlot(_ hostname: String) -> RouteSlot {
        RouteSlot(
            kind: .privateOverlay,
            scope: isTailscaleIPv4(hostname)
                ? "tailscale-ipv4"
                : SparkConnectionPath.isTailscaleIPv6(hostname) ? "tailscale-ipv6" : "tailscale-dns"
        )
    }

    func unregisterPrivateOverlay(currentRoute: URL) {
        guard let entry = library.entry(id: targetID),
            let nodeID = entry.coordinatorNodeID,
            let member = entry.member(nodeID: nodeID)
        else { return }
        let liveLocalRoute = member.routes.first {
            $0.kind != .privateOverlay && $0.baseURL == currentRoute
        }
        library.removeRoutes(entryID: targetID, nodeID: nodeID, kind: .privateOverlay)
        if let liveLocalRoute {
            library.markReachable(entryID: targetID, nodeID: nodeID, route: liveLocalRoute)
        }
    }

    /// A MagicDNS name: lowercase labels under ts.net, nothing else.
    static func isTailscaleName(_ hostname: String) -> Bool {
        let lowered = hostname.lowercased()
        guard lowered.hasSuffix(".ts.net"), lowered.count <= 253 else { return false }
        let labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 3
            && labels.allSatisfy { label in
                !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                    && label.unicodeScalars.allSatisfy {
                        CharacterSet.alphanumerics.contains($0) || $0 == "-"
                    }
            }
    }

    private static func isTailscaleIPv4(_ hostname: String) -> Bool {
        let parts = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
            let first = UInt8(parts[0]),
            let second = UInt8(parts[1]),
            UInt8(parts[2]) != nil,
            UInt8(parts[3]) != nil
        else { return false }
        return first == 100 && (64...127).contains(second)
    }
}
