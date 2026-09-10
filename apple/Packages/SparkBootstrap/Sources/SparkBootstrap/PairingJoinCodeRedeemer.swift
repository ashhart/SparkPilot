import Foundation
import SparkSecurity
import SparkTransport

public protocol PairingJoinCodeRedeeming: Sendable {
    func redeem(code: String, route: URL) async throws -> AdditionalDevicePairingPackage

    func redeem(code: String, route: URL, trustedFingerprint: String) async throws
        -> AdditionalDevicePairingPackage
}

// Older injected redeemers must explicitly implement authenticated code exchange. Never downgrade a code-only request to an unpinned bearer-code request.
extension PairingJoinCodeRedeeming {
    public func redeem(code: String, route: URL) async throws -> AdditionalDevicePairingPackage {
        throw PairingJoinCodeError.unavailable
    }
}

public enum PairingJoinCodeError: Error, Equatable, Sendable {
    case invalidCode
    case insecureRoute
    case invalidFingerprint
    case unavailable
    case runtimeUpdateRequired
    case rejected
    case malformedResponse
    case certificateMismatch
    /// The node has spent its guessing budget; the code itself may still be valid once the wait passes.
    case tooManyAttempts(retryAfterSeconds: Int)
}

public struct HTTPSPairingJoinCodeRedeemer: PairingJoinCodeRedeeming {
    public init() {}

    /// Read the runtime's retry_after_seconds detail, defaulting to the full lockout window.
    static func retryAfterSeconds(in data: Data) -> Int {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let details = (object?["error"] as? [String: Any])?["details"] as? [String: Any]
        return max(1, details?["retry_after_seconds"] as? Int ?? 900)
    }

    public func redeem(code: String, route: URL, trustedFingerprint: String) async throws
        -> AdditionalDevicePairingPackage
    {
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            throw PairingJoinCodeError.invalidCode
        }
        guard route.scheme?.lowercased() == "https", route.host != nil else {
            throw PairingJoinCodeError.insecureRoute
        }

        guard let fingerprint = Self.normalizedFingerprint(trustedFingerprint) else {
            throw PairingJoinCodeError.invalidFingerprint
        }
        let transport = try URLSessionPinnedTransport(pin: fingerprint)

        var request = URLRequest(
            url: route.appendingPathComponent("api/v1/pairing/join-codes/redeem")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(JoinCodeRequest(code: code))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.perform(request)
        } catch PinnedTransportError.certificateRejected {
            throw PairingJoinCodeError.certificateMismatch
        } catch {
            throw PairingJoinCodeError.unavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw PairingJoinCodeError.malformedResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 {
                throw PairingJoinCodeError.tooManyAttempts(
                    retryAfterSeconds: Self.retryAfterSeconds(in: data)
                )
            }
            throw PairingJoinCodeError.rejected
        }
        let wire: JoinPackage
        do {
            wire = try JSONDecoder().decode(JoinPackage.self, from: data)
        } catch {
            throw PairingJoinCodeError.malformedResponse
        }
        guard fingerprint == wire.tlsFingerprint.lowercased() else {
            throw PairingJoinCodeError.certificateMismatch
        }
        let package = AdditionalDevicePairingPackage(
            nodeName: wire.nodeName,
            tlsFingerprint: wire.tlsFingerprint,
            authorityPublicKey: wire.authorityPublicKey,
            invitation: wire.invitation,
            localHint: route.absoluteString
        )
        _ = try package.qrPayload()
        return package
    }

    /// Accept only a full SHA-256 pin transferred from a paired owner, never a discovery hint.
    public static func normalizedFingerprint(_ raw: String) -> String? {
        let value = raw.filter { !$0.isWhitespace && $0 != ":" }.lowercased()
        guard value.utf8.count == 64,
            value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        return value
    }
}

private struct JoinCodeRequest: Encodable {
    let code: String
}

private struct JoinPackage: Decodable {
    let nodeName: String
    let tlsFingerprint: String
    let authorityPublicKey: String
    let invitation: PairingInvitation

    enum CodingKeys: String, CodingKey {
        case nodeName = "node_name"
        case tlsFingerprint = "tls_fingerprint"
        case authorityPublicKey = "authority_public_key"
        case invitation
    }
}
