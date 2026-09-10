import Foundation

/// Encode remote invitation QR data while leaving signature and authority verification to the pairing flow before connection.
public enum RemoteInvitationQR {
    /// Distinguish invitation QR payloads from other formats accepted by onboarding.
    public static let schemePrefix = "spark-invite:"

    /// Prefix compact signed invitation JSON for QR transport.
    public static func payload(for invitation: PairingInvitation) throws -> String {
        guard let signature = invitation.signature, !signature.isEmpty else {
            throw RemoteInvitationQRError.unsignedInvitation
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(invitation)
        return schemePrefix + String(decoding: data, as: UTF8.self)
    }

    /// Decode and shape-check a scanned payload.
    public static func invitation(fromPayload payload: String) throws -> PairingInvitation {
        guard payload.hasPrefix(schemePrefix) else {
            throw RemoteInvitationQRError.notAnInvitation
        }
        let json = String(payload.dropFirst(schemePrefix.count))
        let invitation = try JSONDecoder().decode(PairingInvitation.self, from: Data(json.utf8))
        guard let signature = invitation.signature, !signature.isEmpty else {
            throw RemoteInvitationQRError.unsignedInvitation
        }
        return invitation
    }

    /// Reject locally stale invitations while the server enforces authoritative expiry and single use (§10.5.3).
    public static func isLocallyPlausible(
        _ invitation: PairingInvitation,
        now: Date = Date()
    ) -> Bool {
        guard let expires = expiryDate(invitation.expiresAt) else { return false }
        return expires > now
    }

    /// Accept optional fractional RFC 3339 expiry seconds while rejecting malformed invitation lifetimes.
    static func expiryDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let fractional = formatter.date(from: text) { return fractional }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

public enum RemoteInvitationQRError: Error, Sendable, Equatable {
    case unsignedInvitation
    case notAnInvitation
}
