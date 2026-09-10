import Foundation
import SparkLibrary

/// The Spark's own OpenAI-compatible base URL on the path in use, and what changes for a tool set up with the other one.
public struct SparkAPIAddress: Equatable, Sendable {
    public let path: SparkConnectionPath
    /// `https://<host>:<port>/v1`, the address the Spark itself answers on over this path.
    public let baseURL: URL

    /// The route the app is using for this Spark; nil without a host.
    public init?(route: URL) {
        guard let host = route.host(), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = route.scheme ?? "https"
        components.host = host
        components.port = route.port
        components.path = "/v1"
        guard let url = components.url else { return nil }
        path = SparkConnectionPath.resolve(url: route)
        baseURL = url
    }

    /// The address over Tailscale for a Spark reached locally now: its Tailscale name on the same port.
    public static func overlay(hostname: String, basedOn route: URL) -> SparkAPIAddress? {
        let lowered = hostname.lowercased()
        guard lowered.hasSuffix(".ts.net") || SparkConnectionPath.isTailscaleIPv4(lowered),
            var components = URLComponents(url: route, resolvingAgainstBaseURL: false)
        else { return nil }
        components.host = lowered
        components.path = ""
        components.query = nil
        guard let overlayRoute = components.url else { return nil }
        return SparkAPIAddress(route: overlayRoute)
    }

    public var baseURLText: String { baseURL.absoluteString }

    /// Which address a tool needs right now, and that it changes with the path.
    public var note: String {
        switch path.transport {
        case .local: String(localized: .sparkAPIAddressOnYourNetwork(baseURLText))
        case .unknown: String(localized: .pair(String(localized: "Spark API address"), baseURLText))
        case .tailscale: String(localized: .sparkAPIAddressOverTailscale(baseURLText))
        }
    }

    /// Apps launched from a Mac never carry the Spark's address; the bridge in front of them follows the path.
    public static var bridgeNote: String {
        String(
            localized: """
                Apps launched from SparkPilot on a Mac talk to a bridge on that Mac at 127.0.0.1, which \
                forwards to the Spark on the path in use when the app was launched. The bridge address \
                does not change between home and away.
                """
        )
    }

    /// Where a tool set up by hand keeps the Spark's address, so the owner knows what to update away from home.
    public static var harnessNote: String {
        String(
            localized: """
                A tool you pointed at the Spark's own address needs the address above when the path \
                changes: OPENAI_BASE_URL in a shell, ANTHROPIC_BASE_URL for Claude Code, \
                model_providers.spark.base_url for Codex, provider.spark.options.baseURL for OpenCode, \
                providers.spark.base_url for Hermes Agent, providers.spark.baseUrl for Oh My Pi.
                """
        )
    }
}
