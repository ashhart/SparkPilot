import Foundation
import SparkAPI
import SparkBootstrap

/// One way a joining guest can try to reach the Spark, in the order the app tries them.
public struct SharedAccessRoute: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case local
        case tailnet
    }

    public let url: URL
    public let kind: Kind

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

/// Work out where a guest should try to reach the Spark, and what to say when nothing answers.
public enum SharedAccessJoin {
    /// The signed routes, local first, then the tailnet name. Only https addresses with no credentials.
    public static func candidateRoutes(
        for package: AdditionalDevicePairingPackage
    ) -> [SharedAccessRoute] {
        var routes: [SharedAccessRoute] = []
        var seen = Set<String>()
        func add(_ raw: String?, _ kind: SharedAccessRoute.Kind) {
            guard let raw, let url = URL(string: raw), isSafe(url),
                seen.insert(url.absoluteString).inserted
            else { return }
            routes.append(SharedAccessRoute(url: url, kind: kind))
        }
        // The invitation's own routes are signed; the outer local hint is not, so it comes last.
        add(package.invitation.localEndpoint, .local)
        add(package.invitation.remoteEndpoint, .tailnet)
        if let hostname = package.invitation.remoteHostname, !hostname.isEmpty {
            add("https://\(hostname):7443", .tailnet)
        }
        add(package.localHint, .local)
        return routes
    }

    static func isSafe(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && url.host != nil
    }

    /// Name the path that failed and what the friend can do about it.
    public static func unreachableMessage(tried routes: [SharedAccessRoute]) -> String {
        let triedLocal = routes.contains { $0.kind == .local }
        let triedTailnet = routes.contains { $0.kind == .tailnet }
        if routes.isEmpty {
            return String(
                localized:
                    "This invitation carries no address for the Spark. Ask its owner for a new one."
            )
        }
        if triedLocal && triedTailnet {
            return String(
                localized:
                    "The Spark did not answer on your network or over Tailscale. Check you are signed in to Tailscale and that the owner has accepted you."
            )
        }
        if triedTailnet {
            return String(
                localized:
                    "The Spark did not answer over Tailscale. Check you are signed in and that the owner has accepted you into their network."
            )
        }
        return String(
            localized:
                "The Spark did not answer on this network. Join the owner's Wi-Fi, or install Tailscale and ask them to share the Spark with you."
        )
    }

    /// The one line the joining screen shows about what to install before tapping through.
    public static func preparationAdvice(
        for package: AdditionalDevicePairingPackage
    ) -> String {
        guard package.invitation.isSharedAccess else {
            return String(localized: "Pairing this device with the Spark.")
        }
        if package.invitation.remoteHostname?.isEmpty == false {
            return String(
                localized:
                    "You can join from the owner's Wi-Fi, or from anywhere once they have accepted you into their Tailscale network."
            )
        }
        return String(
            localized: "Join the owner's Wi-Fi first: this Spark has no remote address yet."
        )
    }
}

extension SharedAccessJoin {
    /// Whether a failure means the Spark never answered, rather than answering with a refusal.
    public static func reachabilityFailure(_ error: (any Error)?) -> Bool {
        guard let error else { return true }
        if error is URLError { return true }
        if let api = error as? APIError { return api.statusCode == nil }
        return false
    }
}
