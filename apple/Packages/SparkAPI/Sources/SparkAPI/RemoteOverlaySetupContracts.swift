import Foundation

/// What the Spark's own Tailscale client needs before the private route can exist (`RemoteOverlaySetup.state`).
public enum RemoteOverlaySetupState: String, Sendable, Equatable, Codable {
    case notInstalled = "not_installed"
    case stopped
    case loginRequired = "login_required"
    case approvalRequired = "approval_required"
    case connecting
    case ready
    case unavailable
}

/// `GET /api/v1/remote/overlay/setup` — the helper's live Tailscale state, with the owner's sign-in link while an enable waits for it.
public struct RemoteOverlaySetup: Sendable, Equatable, Codable {
    public let provider: String
    public let state: RemoteOverlaySetupState
    /// Accepted only on the exact `https://login.tailscale.com/a/` origin; anything else decodes as nil.
    public let authorizationURL: URL?
    public let hostname: String?
    public let address: String?
    public let tailnet: String?
    public let installable: Bool?
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case provider, state, hostname, address, tailnet, installable, detail
        case authorizationURL = "authorization_url"
    }

    public init(
        provider: String = "tailscale",
        state: RemoteOverlaySetupState,
        authorizationURL: URL? = nil,
        hostname: String? = nil,
        address: String? = nil,
        tailnet: String? = nil,
        installable: Bool? = nil,
        detail: String? = nil
    ) {
        self.provider = provider
        self.state = state
        self.authorizationURL = authorizationURL.flatMap { Self.isTrustedSignInLink($0) ? $0 : nil }
        self.hostname = hostname
        self.address = address
        self.tailnet = tailnet
        self.installable = installable
        self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            provider: try container.decode(String.self, forKey: .provider),
            state: try container.decode(RemoteOverlaySetupState.self, forKey: .state),
            authorizationURL: try container.decodeIfPresent(String.self, forKey: .authorizationURL)
                .flatMap(URL.init(string:)),
            hostname: try container.decodeIfPresent(String.self, forKey: .hostname),
            address: try container.decodeIfPresent(String.self, forKey: .address),
            tailnet: try container.decodeIfPresent(String.self, forKey: .tailnet),
            installable: try container.decodeIfPresent(Bool.self, forKey: .installable),
            detail: try container.decodeIfPresent(String.self, forKey: .detail)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(authorizationURL?.absoluteString, forKey: .authorizationURL)
        try container.encodeIfPresent(hostname, forKey: .hostname)
        try container.encodeIfPresent(address, forKey: .address)
        try container.encodeIfPresent(tailnet, forKey: .tailnet)
        try container.encodeIfPresent(installable, forKey: .installable)
        try container.encodeIfPresent(detail, forKey: .detail)
    }

    /// The owner is asked to sign in or a tailnet administrator to approve the Spark.
    public var needsOwner: Bool {
        state == .loginRequired || state == .approvalRequired
    }

    /// Only Tailscale's own sign-in origin, over HTTPS, with a plain token path and nothing else attached.
    public static func isTrustedSignInLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
            url.host()?.lowercased() == "login.tailscale.com",
            url.port == nil, url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil
        else { return false }
        let components = url.pathComponents
        guard components.count == 3, components[1] == "a" else { return false }
        let token = components[2]
        return !token.isEmpty && token.count <= 256
            && token.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}
