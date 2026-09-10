import Foundation

#if os(iOS)
    import CoreLocation
    import NetworkExtension
#elseif os(macOS)
    import CoreLocation
    @preconcurrency import CoreWLAN
#endif

public enum SetupNetworkCredentialError: Error, Sendable, Equatable {
    case emptySSID
    case ssidTooLong
    case ssidPrefixTooShort
    case ssidPrefixTooLong
    case invalidPassphrase
    case unsupportedSetupURL
}

/// Distinguish exact SSIDs from prefix requests whose final network is chosen by iOS and read back after association.
public enum SetupNetworkMatch: Sendable, Equatable {
    /// Retain the full setup SSID from the Quick Start card or its code.
    case exactSSID(String)
    /// Let the system present nearby networks matching the owner's partial setup label.
    case ssidPrefix(String)

    /// Whether an observed network name satisfies this request.
    public func matches(_ ssid: String) -> Bool {
        switch self {
        case .exactSSID(let expected):
            return ssid.caseInsensitiveCompare(expected) == .orderedSame
        case .ssidPrefix(let prefix):
            return ssid.lowercased().hasPrefix(prefix.lowercased())
        }
    }

    /// What to show the owner while the join is in flight.
    public var displayName: String {
        switch self {
        case .exactSSID(let ssid): return ssid
        case .ssidPrefix(let prefix): return "\(prefix)…"
        }
    }
}

/// Discard temporary setup credentials immediately after the join attempt.
public struct SetupNetworkCredentials: Sendable, Equatable, CustomDebugStringConvertible {
    public let match: SetupNetworkMatch
    public let passphrase: String
    public let setupPage: URL?

    /// Join one named network.
    public init(ssid: String, passphrase: String, setupPage: URL? = nil) throws {
        let cleanSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSSID.isEmpty else {
            throw SetupNetworkCredentialError.emptySSID
        }
        guard cleanSSID.lengthOfBytes(using: .utf8) <= 32 else {
            throw SetupNetworkCredentialError.ssidTooLong
        }
        try self.init(
            match: .exactSSID(cleanSSID),
            passphrase: passphrase,
            setupPage: setupPage
        )
    }

    /// Validate Wi-Fi prefixes against the platform's three-to-32-character bound before requesting system selection.
    public init(ssidPrefix: String, passphrase: String, setupPage: URL? = nil) throws {
        let cleanPrefix = ssidPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanPrefix.lengthOfBytes(using: .utf8) >= 3 else {
            throw SetupNetworkCredentialError.ssidPrefixTooShort
        }
        guard cleanPrefix.lengthOfBytes(using: .utf8) <= 32 else {
            throw SetupNetworkCredentialError.ssidPrefixTooLong
        }
        try self.init(
            match: .ssidPrefix(cleanPrefix),
            passphrase: passphrase,
            setupPage: setupPage
        )
    }

    private init(match: SetupNetworkMatch, passphrase: String, setupPage: URL?) throws {
        guard Self.isValidWPAPassphrase(passphrase) else {
            throw SetupNetworkCredentialError.invalidPassphrase
        }
        // A printed code could name any host; the admin password only ever goes to the setup network.
        if let setupPage, !SetupPageAddress.isOnSetupNetwork(setupPage) {
            throw SetupNetworkCredentialError.unsupportedSetupURL
        }

        self.match = match
        self.passphrase = passphrase
        self.setupPage = setupPage
    }

    /// Retain a full owner-supplied SSID only; prefix-based joins learn the selected name after system confirmation.
    public var exactSSID: String? {
        if case .exactSSID(let ssid) = match { return ssid }
        return nil
    }

    public var debugDescription: String {
        "SetupNetworkCredentials(match: \(match.displayName), passphrase: <redacted>, setupPage: \(String(describing: setupPage)))"
    }

    private static func isValidWPAPassphrase(_ value: String) -> Bool {
        let byteCount = value.lengthOfBytes(using: .utf8)
        if (8...63).contains(byteCount) {
            return true
        }
        return byteCount == 64 && value.allSatisfy(\.isHexDigit)
    }
}

public enum QuickStartCodeError: Error, Sendable, Equatable {
    case unsupportedFormat
    case missingSSID
    case missingPassphrase
    case unsupportedSecurity
    case invalidCredentials(SetupNetworkCredentialError)
}

/// Accept standard Wi-Fi QR payloads and the Spark-specific setup URL form.
public enum QuickStartCodeParser {
    public static func parse(_ payload: String) throws -> SetupNetworkCredentials {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasPrefix("WIFI:") {
            return try parseWiFiPayload(String(trimmed.dropFirst(5)))
        }
        if let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == "spark",
            components.host?.lowercased() == "setup"
        {
            return try parseSparkURL(components)
        }
        throw QuickStartCodeError.unsupportedFormat
    }

    private static func parseWiFiPayload(_ body: String) throws -> SetupNetworkCredentials {
        let fields = splitEscaped(body, separator: ";").reduce(into: [String: String]()) {
            result,
            field in
            guard let separator = firstUnescapedColon(in: field) else { return }
            let key = String(field[..<separator]).uppercased()
            let valueStart = field.index(after: separator)
            result[key] = unescape(String(field[valueStart...]))
        }

        guard let ssid = fields["S"], !ssid.isEmpty else {
            throw QuickStartCodeError.missingSSID
        }
        guard let passphrase = fields["P"], !passphrase.isEmpty else {
            throw QuickStartCodeError.missingPassphrase
        }
        let security = fields["T"]?.uppercased() ?? "WPA"
        guard security == "WPA" || security == "WPA2" else {
            throw QuickStartCodeError.unsupportedSecurity
        }

        do {
            return try SetupNetworkCredentials(ssid: ssid, passphrase: passphrase)
        } catch let error as SetupNetworkCredentialError {
            throw QuickStartCodeError.invalidCredentials(error)
        }
    }

    private static func parseSparkURL(_ components: URLComponents) throws -> SetupNetworkCredentials
    {
        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name.lowercased(), $0.value ?? "")
            }
        )
        guard let ssid = values["ssid"], !ssid.isEmpty else {
            throw QuickStartCodeError.missingSSID
        }
        guard let passphrase = values["password"], !passphrase.isEmpty else {
            throw QuickStartCodeError.missingPassphrase
        }

        let setupPage: URL?
        if let rawPage = values["page"], !rawPage.isEmpty {
            setupPage = URL(string: rawPage)
        } else {
            setupPage = nil
        }

        do {
            return try SetupNetworkCredentials(
                ssid: ssid,
                passphrase: passphrase,
                setupPage: setupPage
            )
        } catch let error as SetupNetworkCredentialError {
            throw QuickStartCodeError.invalidCredentials(error)
        }
    }

    private static func splitEscaped(_ value: String, separator: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var escaped = false

        for character in value {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == separator {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped {
            current.append("\\")
        }
        if !current.isEmpty {
            fields.append(current)
        }
        return fields
    }

    private static func firstUnescapedColon(in value: String) -> String.Index? {
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == ":" {
                return index
            }
        }
        return nil
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped {
            result.append("\\")
        }
        return result
    }
}

public enum SetupNetworkJoinError: Error, Sendable, Equatable {
    case unsupportedPlatform
    case invalidConfiguration
    case invalidSSIDPrefix
    case userDenied
    case systemDenied
    case requestPending
    case applicationNotForeground
    case connectionTimedOut
    case failed(code: Int)
}

public protocol SetupNetworkJoining: AnyObject {
    /// Use NEHotspotConfiguration on iOS/iPadOS and Core WLAN on Mac for system-performed association.
    @MainActor
    var canJoinSetupNetwork: Bool { get }

    /// Return the network actually joined, including the owner's system-selected prefix match.
    @MainActor
    @discardableResult
    func join(_ credentials: SetupNetworkCredentials) async throws -> String

    @MainActor
    func forget(ssid: String)
}

public protocol CurrentWiFiNetworkReading: AnyObject {
    @MainActor
    func currentSSID() async -> String?

    /// Read the SSID only if the platform already allows it; never prompt for location on a passive check.
    @MainActor
    func currentSSID(requestingPermission: Bool) async -> String?
}

extension CurrentWiFiNetworkReading {
    @MainActor
    public func currentSSID(requestingPermission: Bool) async -> String? {
        await currentSSID()
    }
}
