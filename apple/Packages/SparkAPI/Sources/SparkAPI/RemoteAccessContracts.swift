import Foundation
import SparkCore

/// Remote access mode (`RemoteStatus.mode`).
public enum RemoteMode: String, Sendable, Equatable, Codable {
    case disabled
    case privateOverlay = "private_overlay"
}

/// Decode the reserved failed remote state even though current runtimes publish disabled, starting, healthy or degraded.
public enum RemoteHealth: String, Sendable, Equatable, Codable {
    case disabled
    case starting
    case healthy
    case degraded
    case failed
}

/// `GET /api/v1/remote` — the remote access status document.
public struct RemoteStatus: Sendable, Equatable, Codable {
    public let enabled: Bool
    public let mode: RemoteMode
    public let health: RemoteHealth
    public let hostname: String?
    public let availableModes: [RemoteMode]
    public let privateOverlayProvider: String?
    /// The live 100.64/10 address beside `hostname`, which is the MagicDNS name once the Spark's Tailscale reports one.
    public let privateOverlayAddress: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case mode
        case health
        case hostname
        case availableModes = "available_modes"
        case privateOverlayProvider = "private_overlay_provider"
        case privateOverlayAddress = "private_overlay_address"
    }

    public init(
        enabled: Bool,
        mode: RemoteMode,
        health: RemoteHealth,
        hostname: String? = nil,
        availableModes: [RemoteMode] = [],
        privateOverlayProvider: String? = nil,
        privateOverlayAddress: String? = nil
    ) {
        self.enabled = enabled
        self.mode = mode
        self.health = health
        self.hostname = hostname
        self.availableModes = availableModes
        self.privateOverlayProvider = privateOverlayProvider
        self.privateOverlayAddress = privateOverlayAddress
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        mode = try container.decode(RemoteMode.self, forKey: .mode)
        health = try container.decode(RemoteHealth.self, forKey: .health)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        availableModes =
            try container.decodeIfPresent([RemoteMode].self, forKey: .availableModes) ?? []
        privateOverlayProvider = try container.decodeIfPresent(
            String.self,
            forKey: .privateOverlayProvider
        )
        privateOverlayAddress = try container.decodeIfPresent(
            String.self,
            forKey: .privateOverlayAddress
        )
    }
}

/// `POST /api/v1/remote/enable` request body.
public struct EnableRemoteRequest: Sendable, Equatable {
    public let mode: RemoteMode
    public let acceptedPreviewDigest: String

    public init(
        mode: RemoteMode,
        acceptedPreviewDigest: String
    ) {
        self.mode = mode
        self.acceptedPreviewDigest = acceptedPreviewDigest
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case acceptedPreviewDigest = "accepted_preview_digest"
    }
}

extension EnableRemoteRequest: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode.rawValue, forKey: .mode)
        try container.encode(acceptedPreviewDigest, forKey: .acceptedPreviewDigest)
    }
}

public struct RemotePreviewRequest: Sendable, Equatable, Encodable {
    public let mode: RemoteMode

    public init(mode: RemoteMode) {
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey {
        case mode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode.rawValue, forKey: .mode)
    }
}

public struct DisableRemoteRequest: Sendable, Equatable, Encodable {
    public let acceptedPreviewDigest: String

    public init(acceptedPreviewDigest: String) {
        self.acceptedPreviewDigest = acceptedPreviewDigest
    }

    enum CodingKeys: String, CodingKey {
        case acceptedPreviewDigest = "accepted_preview_digest"
    }
}
