import Foundation

/// Mint invitations under sparkpilot:// to avoid the generic spark:// scheme; still accept legacy links.
public enum PairingLinkScheme: Sendable {
    /// The scheme only this app registers, and the one every freshly minted link carries.
    public static let appScheme = "sparkpilot"
    /// The unqualified scheme older invitations were minted with; still accepted, never minted.
    public static let legacyScheme = "spark"

    /// The prefix a new link for a route ("pair/", "pair-batch/") is built with.
    public static func mint(_ route: String) -> String { "\(appScheme)://\(route)" }

    /// Every prefix a stored, scanned or typed link may legitimately arrive with, newest first.
    public static func accepted(_ route: String) -> [String] {
        ["\(appScheme)://\(route)", "\(legacyScheme)://\(route)"]
    }

    /// QA-05: the payload after whichever accepted prefix it carries, whatever a keyboard capitalised; nil when it carries none.
    public static func body(of payload: String, route: String) -> String? {
        let lowered = payload.lowercased()
        for prefix in accepted(route) where lowered.hasPrefix(prefix) {
            return String(payload.dropFirst(prefix.count))
        }
        return nil
    }

    /// Whether a payload names this route under either scheme, ignoring case.
    public static func carries(_ payload: String, route: String) -> Bool {
        body(of: payload, route: route) != nil
    }
}
