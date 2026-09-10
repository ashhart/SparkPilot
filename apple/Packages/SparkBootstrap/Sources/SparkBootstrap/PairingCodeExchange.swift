import CCryptoBoringSSL
import CryptoKit
import Foundation
import Security
import SparkSecurity

/// Single-use SPAKE2 exchange: the short code never leaves this device, and the authenticated encrypted package supplies the certificate pin for ordinary pairing.
final class PairingCodeExchange {
    static let sealLabel = Data("spark-pairing-seal-v2".utf8)
    private let context: OpaquePointer
    let message: Data

    init(code: String) throws {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw PairingJoinCodeError.invalidCode
        }
        let client = Array("SparkPilot pairing v2 client".utf8)
        let server = Array("SparkPilot pairing v2 server".utf8)
        guard
            let context = CCryptoBoringSSL_SPAKE2_CTX_new(
                spake2_role_alice,
                client,
                client.count,
                server,
                server.count
            )
        else { throw PairingJoinCodeError.unavailable }
        let password = Array(SHA256.hash(data: Data("spark-pairing-join-code-v1:\(code)".utf8)))
        var output = [UInt8](repeating: 0, count: 32)
        var count = 0
        guard
            CCryptoBoringSSL_SPAKE2_generate_msg(
                context,
                &output,
                &count,
                output.count,
                password,
                password.count
            ) == 1, count == 32
        else {
            CCryptoBoringSSL_SPAKE2_CTX_free(context)
            throw PairingJoinCodeError.unavailable
        }
        self.context = context
        message = Data(output)
    }

    deinit { CCryptoBoringSSL_SPAKE2_CTX_free(context) }

    func open(message: Data, sealed: Data) throws -> Data {
        guard message.count == 32, sealed.count >= 28, sealed.count <= 65536 else {
            throw PairingJoinCodeError.malformedResponse
        }
        var key = [UInt8](repeating: 0, count: 64)
        defer {
            _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        var count = 0
        guard
            CCryptoBoringSSL_SPAKE2_process_msg(
                context,
                &key,
                &count,
                key.count,
                Array(message),
                message.count
            ) == 1, count == 64
        else { throw PairingJoinCodeError.rejected }
        let cipherKey = SymmetricKey(data: SHA256.hash(data: Self.sealLabel + Data(key)))
        do {
            return try AES.GCM.open(
                AES.GCM.SealedBox(combined: sealed),
                using: cipherKey,
                authenticating: Self.sealLabel
            )
        } catch { throw PairingJoinCodeError.rejected }
    }
}

extension HTTPSPairingJoinCodeRedeemer {
    /// This transport carries only a randomized SPAKE2 share, never the code or a grant. After PAKE authentication, bind its TLS certificate to the sealed pin.
    public func redeem(code: String, route: URL) async throws -> AdditionalDevicePairingPackage {
        guard route.scheme?.lowercased() == "https", let host = route.host,
            route.user == nil, route.password == nil
        else { throw PairingJoinCodeError.insecureRoute }
        let exchange = try PairingCodeExchange(code: code)
        let delegate = CodeExchangeTransport(host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        var request = URLRequest(
            url: route.appendingPathComponent("api/v1/pairing/join-codes/exchange")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CodeExchangeRequest(message: exchange.message.base64EncodedString())
        )
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let response = response as? HTTPURLResponse else {
            throw PairingJoinCodeError.malformedResponse
        }
        guard response.expectedContentLength <= 65536 else {
            throw PairingJoinCodeError.malformedResponse
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65536 else { throw PairingJoinCodeError.malformedResponse }
            data.append(byte)
        }
        if response.statusCode == 429 {
            throw PairingJoinCodeError.tooManyAttempts(
                retryAfterSeconds: Self.retryAfterSeconds(in: data)
            )
        }
        if response.statusCode == 404 {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = (object?["error"] as? [String: Any])?["code"] as? String
            if code != "JOIN_CODE_INVALID" { throw PairingJoinCodeError.runtimeUpdateRequired }
        }
        guard response.statusCode == 200 else { throw PairingJoinCodeError.rejected }
        let responseBody = try JSONDecoder().decode(CodeExchangeResponse.self, from: data)
        guard let message = Data(base64Encoded: responseBody.message),
            let sealed = Data(base64Encoded: responseBody.sealedPackage)
        else { throw PairingJoinCodeError.malformedResponse }
        let plaintext = try exchange.open(message: message, sealed: sealed)
        let package = try JSONDecoder().decode(CodeExchangePackage.self, from: plaintext)
        guard let fingerprint = Self.normalizedFingerprint(package.tlsFingerprint),
            fingerprint == delegate.fingerprint
        else {
            throw PairingJoinCodeError.certificateMismatch
        }
        let result = AdditionalDevicePairingPackage(
            nodeName: package.nodeName,
            tlsFingerprint: package.tlsFingerprint,
            authorityPublicKey: package.authorityPublicKey,
            invitation: package.invitation,
            localHint: route.absoluteString
        )
        _ = try result.qrPayload()
        return result
    }
}

private struct CodeExchangeRequest: Encodable { let message: String }
private struct CodeExchangeResponse: Decodable {
    let message: String
    let sealedPackage: String
    enum CodingKeys: String, CodingKey {
        case message
        case sealedPackage = "sealed_package"
    }
}
private struct CodeExchangePackage: Decodable {
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

/// Private to this single unauthenticated PAKE request, never an ordinary API session.
private final class CodeExchangeTransport: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
    @unchecked Sendable
{
    let host: String
    private let lock = NSLock()
    private var observedFingerprint: String?
    var fingerprint: String? { lock.withLock { observedFingerprint } }
    init(host: String) { self.host = host }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            challenge.protectionSpace.host == host,
            let trust = challenge.protectionSpace.serverTrust,
            let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = certificates.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        lock.withLock { observedFingerprint = digest }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
