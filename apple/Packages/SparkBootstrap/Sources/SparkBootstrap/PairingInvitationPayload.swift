import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport

/// Match invitation struct-order canonicalization with omitted optionals and signature:null, distinct from release-manifest canonicalization.
struct PairingInvitationPayload: Sendable {
    let version: Int64
    let nodeID: String
    let clusterID: String?
    let localEndpoint: String?
    let remoteEndpoint: String?
    let authorityFingerprint: String
    let invitationID: String
    let nonce: String
    let issuedByDeviceID: String?
    let recipientDeviceID: String?
    let recipientPublicKeyFingerprint: String?
    let role: String
    let expiresAt: String
    let nodeName: String?
    let tlsFingerprint: String?
    let remoteHostname: String?
    let sharedAccess: SharedAccessSummary?
    let signature: String

    /// Forward the invitation to the claim endpoint without changing its received representation.
    let rawInvitation: PairingInvitation

    init(json: JSONValue) throws {
        guard let members = json.objectValue else {
            throw FirstOwnerPairingError.malformedInvitation("not a JSON object")
        }
        func required(_ key: String) throws -> String {
            guard let value = members[key]?.stringValue, !value.isEmpty else {
                throw FirstOwnerPairingError.malformedInvitation("missing \(key)")
            }
            return value
        }
        guard let version = members["version"]?.integerValue else {
            throw FirstOwnerPairingError.malformedInvitation("missing version")
        }
        self.version = version
        self.nodeID = try required("node_id")
        self.clusterID = members["cluster_id"]?.stringValue
        self.localEndpoint = members["local_endpoint"]?.stringValue
        self.remoteEndpoint = members["remote_endpoint"]?.stringValue
        self.authorityFingerprint = try required("authority_fingerprint")
        self.invitationID = try required("invitation_id")
        self.nonce = try required("nonce")
        self.issuedByDeviceID = members["issued_by_device_id"]?.stringValue
        self.recipientDeviceID = members["recipient_device_id"]?.stringValue
        self.recipientPublicKeyFingerprint =
            members["recipient_public_key_fingerprint"]?.stringValue
        self.role = try required("role")
        self.expiresAt = try required("expires_at")
        self.nodeName = members["node_name"]?.stringValue
        self.tlsFingerprint = members["tls_fingerprint"]?.stringValue
        self.remoteHostname = members["remote_hostname"]?.stringValue
        self.sharedAccess = try members["shared_access"].map(Self.sharedAccess(from:))
        self.signature = try required("signature")

        self.rawInvitation = PairingInvitation(
            version: Int(version),
            nodeID: nodeID,
            authorityFingerprint: authorityFingerprint,
            invitationID: invitationID,
            nonce: nonce,
            issuedByDeviceID: issuedByDeviceID,
            recipientDeviceID: recipientDeviceID,
            recipientPublicKeyFingerprint: recipientPublicKeyFingerprint,
            role: role,
            expiresAt: expiresAt,
            signature: signature,
            clusterID: clusterID,
            localEndpoint: localEndpoint,
            remoteEndpoint: remoteEndpoint,
            nodeName: nodeName,
            tlsFingerprint: tlsFingerprint,
            remoteHostname: remoteHostname,
            sharedAccess: sharedAccess
        )
    }

    /// Read the signed guest limits, refusing a shape the runtime would not have issued.
    private static func sharedAccess(from json: JSONValue) throws -> SharedAccessSummary {
        guard let members = json.objectValue,
            let displayName = members["display_name"]?.stringValue,
            let timeZone = members["time_zone"]?.stringValue,
            let concurrency = members["max_concurrent_requests"]?.integerValue,
            let budget = members["daily_token_budget"]?.integerValue,
            let models = members["allowed_models"]?.arrayValue,
            let days = members["allowed_hours"]?.arrayValue
        else {
            throw FirstOwnerPairingError.malformedInvitation(
                "shared_access is not the signed shape"
            )
        }
        return SharedAccessSummary(
            displayName: displayName,
            allowedModels: try models.map { entry in
                guard let name = entry.stringValue else {
                    throw FirstOwnerPairingError.malformedInvitation("allowed_models entry")
                }
                return name
            },
            allowedHours: try days.map(Self.day(from:)),
            timeZone: timeZone,
            maxConcurrentRequests: Int(concurrency),
            dailyTokenBudget: Int(budget),
            expiresAt: members["expires_at"]?.integerValue.map(Int.init)
        )
    }

    private static func day(from json: JSONValue) throws -> GuestDaySchedule {
        guard let members = json.objectValue,
            let weekday = members["weekday"]?.integerValue,
            let windows = members["windows"]?.arrayValue
        else {
            throw FirstOwnerPairingError.malformedInvitation("allowed_hours entry")
        }
        return GuestDaySchedule(
            weekday: Int(weekday),
            windows: try windows.map { window in
                guard let members = window.objectValue,
                    let start = members["start_minute"]?.integerValue,
                    let end = members["end_minute"]?.integerValue
                else {
                    throw FirstOwnerPairingError.malformedInvitation("allowed_hours window")
                }
                return GuestHourWindow(startMinute: Int(start), endMinute: Int(end))
            }
        )
    }

    /// Preserve the exact canonical bytes covered by the node signature.
    var canonicalBytes: Data {
        var parts: [String] = []
        func quote(_ value: String) -> String {
            var output = "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": output += "\\\""
                case "\\": output += "\\\\"
                case "\u{08}": output += "\\b"
                case "\u{09}": output += "\\t"
                case "\u{0A}": output += "\\n"
                case "\u{0C}": output += "\\f"
                case "\u{0D}": output += "\\r"
                default:
                    if scalar.value < 0x20 {
                        output += String(format: "\\u%04x", scalar.value)
                    } else {
                        output.unicodeScalars.append(scalar)
                    }
                }
            }
            return output + "\""
        }

        // Declaration order, exactly as the runtime's struct lists them.
        parts.append("\"version\":\(version)")
        parts.append("\"node_id\":\(quote(nodeID))")
        if let clusterID { parts.append("\"cluster_id\":\(quote(clusterID))") }
        if let localEndpoint { parts.append("\"local_endpoint\":\(quote(localEndpoint))") }
        if let remoteEndpoint { parts.append("\"remote_endpoint\":\(quote(remoteEndpoint))") }
        parts.append("\"authority_fingerprint\":\(quote(authorityFingerprint))")
        parts.append("\"invitation_id\":\(quote(invitationID))")
        parts.append("\"nonce\":\(quote(nonce))")
        if let issuedByDeviceID {
            parts.append("\"issued_by_device_id\":\(quote(issuedByDeviceID))")
        }
        if let recipientDeviceID {
            parts.append("\"recipient_device_id\":\(quote(recipientDeviceID))")
        }
        if let recipientPublicKeyFingerprint {
            parts.append(
                "\"recipient_public_key_fingerprint\":\(quote(recipientPublicKeyFingerprint))"
            )
        }
        parts.append("\"role\":\(quote(role))")
        parts.append("\"expires_at\":\(quote(expiresAt))")
        // Version 2 members sit here, before the signature, so version 1 bytes are unchanged.
        if let nodeName { parts.append("\"node_name\":\(quote(nodeName))") }
        if let tlsFingerprint { parts.append("\"tls_fingerprint\":\(quote(tlsFingerprint))") }
        if let remoteHostname { parts.append("\"remote_hostname\":\(quote(remoteHostname))") }
        if let sharedAccess {
            parts.append("\"shared_access\":\(Self.canonicalSharedAccess(sharedAccess, quote))")
        }
        // Present and null: the runtime does not skip this member.
        parts.append("\"signature\":null")
        return Data(("{" + parts.joined(separator: ",") + "}").utf8)
    }

    /// Emit the guest limits in the runtime's declaration order, because they are inside the signature.
    private static func canonicalSharedAccess(
        _ summary: SharedAccessSummary,
        _ quote: (String) -> String
    ) -> String {
        var parts: [String] = []
        parts.append("\"display_name\":\(quote(summary.displayName))")
        let models = summary.allowedModels.map(quote).joined(separator: ",")
        parts.append("\"allowed_models\":[\(models)]")
        let days = summary.allowedHours.map { day in
            let windows = day.windows
                .map { "{\"start_minute\":\($0.startMinute),\"end_minute\":\($0.endMinute)}" }
                .joined(separator: ",")
            return "{\"weekday\":\(day.weekday),\"windows\":[\(windows)]}"
        }
        .joined(separator: ",")
        parts.append("\"allowed_hours\":[\(days)]")
        parts.append("\"time_zone\":\(quote(summary.timeZone))")
        parts.append("\"max_concurrent_requests\":\(summary.maxConcurrentRequests)")
        parts.append("\"daily_token_budget\":\(summary.dailyTokenBudget)")
        if let expiresAt = summary.expiresAt {
            parts.append("\"expires_at\":\(expiresAt)")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    func verify(under authorityKey: Curve25519.Signing.PublicKey) throws {
        guard let signatureBytes = Base64URL.decode(signature), signatureBytes.count == 64 else {
            throw FirstOwnerPairingError.malformedInvitation("signature is not 64 base64url bytes")
        }
        guard authorityKey.isValidSignature(signatureBytes, for: canonicalBytes) else {
            throw FirstOwnerPairingError.invitationSignatureInvalid
        }
    }
}
