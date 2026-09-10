import CCryptoBoringSSL
import CryptoKit
import Foundation
import Testing

@testable import SparkBootstrap

private func answer(_ client: PairingCodeExchange, code: String, plaintext: Data) throws -> (
    Data, Data
) {
    let alice = Array("SparkPilot pairing v2 client".utf8)
    let bob = Array("SparkPilot pairing v2 server".utf8)
    let context = try #require(
        CCryptoBoringSSL_SPAKE2_CTX_new(spake2_role_bob, bob, bob.count, alice, alice.count)
    )
    defer { CCryptoBoringSSL_SPAKE2_CTX_free(context) }
    let password = Array(SHA256.hash(data: Data("spark-pairing-join-code-v1:\(code)".utf8)))
    var message = [UInt8](repeating: 0, count: 32)
    var count = 0
    #expect(
        CCryptoBoringSSL_SPAKE2_generate_msg(
            context,
            &message,
            &count,
            32,
            password,
            password.count
        ) == 1
    )
    var key = [UInt8](repeating: 0, count: 64)
    #expect(
        CCryptoBoringSSL_SPAKE2_process_msg(
            context,
            &key,
            &count,
            64,
            Array(client.message),
            client.message.count
        ) == 1
    )
    let cipher = SymmetricKey(data: SHA256.hash(data: PairingCodeExchange.sealLabel + Data(key)))
    let sealed = try AES.GCM.seal(
        plaintext,
        using: cipher,
        authenticating: PairingCodeExchange.sealLabel
    )
    return (Data(message), try #require(sealed.combined))
}

@Test func pairingCodeAuthenticatesAndOnlyOpensOnce() throws {
    let client = try PairingCodeExchange(code: "012345")
    let plaintext = Data("signed invitation with certificate pin".utf8)
    let (message, sealed) = try answer(client, code: "012345", plaintext: plaintext)
    #expect(try client.open(message: message, sealed: sealed) == plaintext)
    #expect(throws: PairingJoinCodeError.rejected) {
        try client.open(message: message, sealed: sealed)
    }
}

@Test func pairingCodeRejectsWrongCodeTamperingAndAnotherSession() throws {
    let client = try PairingCodeExchange(code: "012345")
    let (message, sealed) = try answer(client, code: "012346", plaintext: Data("secret".utf8))
    #expect(throws: PairingJoinCodeError.rejected) {
        try client.open(message: message, sealed: sealed)
    }
    let second = try PairingCodeExchange(code: "012345")
    let (secondMessage, secondSealed) = try answer(
        second,
        code: "012345",
        plaintext: Data("secret".utf8)
    )
    let other = try PairingCodeExchange(code: "012345")
    #expect(other.message != second.message)
    #expect(throws: PairingJoinCodeError.rejected) {
        try other.open(message: secondMessage, sealed: secondSealed)
    }
    var tampered = secondSealed
    tampered[tampered.count - 1] ^= 1
    #expect(throws: PairingJoinCodeError.rejected) {
        try second.open(message: secondMessage, sealed: tampered)
    }
}

@Test func pairingCodeRejectsMalformedInputs() throws {
    for code in ["12345", "1234567", "１２３４５６", "12345a"] {
        #expect(throws: PairingJoinCodeError.invalidCode) { try PairingCodeExchange(code: code) }
    }
    let client = try PairingCodeExchange(code: "012345")
    #expect(throws: PairingJoinCodeError.malformedResponse) {
        try client.open(message: Data(), sealed: Data())
    }
    #expect(throws: PairingJoinCodeError.malformedResponse) {
        try client.open(
            message: Data(repeating: 0, count: 32),
            sealed: Data(repeating: 0, count: 65537)
        )
    }
}

@Test func pairingCodeTransportRejectsInsecureRoutesBeforeSending() async {
    for route in ["http://spark.invalid", "https://user:secret@spark.invalid"] {
        await #expect(throws: PairingJoinCodeError.insecureRoute) {
            try await HTTPSPairingJoinCodeRedeemer().redeem(
                code: "012345",
                route: URL(string: route)!
            )
        }
    }
}

/// Optional live interop gate: the Rust AWS-LC test answers this Apple BoringSSL client.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SPARK_PAIRING_INTEROP_DIRECTORY"] != nil))
func pairingCodeOpensRustResponse() async throws {
    let directory = URL(
        fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["SPARK_PAIRING_INTEROP_DIRECTORY"]
        )
    )
    let client = try PairingCodeExchange(code: "012345")
    try client.message.write(to: directory.appendingPathComponent("client"), options: .atomic)
    let responseURL = directory.appendingPathComponent("response")
    for _ in 0..<600 {
        if FileManager.default.fileExists(atPath: responseURL.path) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let response = try JSONDecoder().decode(
        InteropResponse.self,
        from: Data(contentsOf: responseURL)
    )
    let message = try #require(Data(base64Encoded: response.message))
    let sealed = try #require(Data(base64Encoded: response.sealedPackage))
    #expect(
        try client.open(message: message, sealed: sealed)
            == Data("Rust to Apple authenticated pairing".utf8)
    )
}

private struct InteropResponse: Decodable {
    let message: String
    let sealedPackage: String
    enum CodingKeys: String, CodingKey {
        case message
        case sealedPackage = "sealed_package"
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SPARK_PAIRING_HTTPS_INTEROP"] == "1"))
func pairingCodeHTTPSInterop() async throws {
    let directory = URL(
        fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["SPARK_PAIRING_INTEROP_DIRECTORY"]
        )
    )
    let detailsURL = directory.appendingPathComponent("https.json")
    for _ in 0..<1200 {
        if FileManager.default.fileExists(atPath: detailsURL.path) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let details = try JSONDecoder().decode(HTTPSInterop.self, from: Data(contentsOf: detailsURL))
    let redeemer = HTTPSPairingJoinCodeRedeemer()
    let package = try await redeemer.redeem(code: details.code, route: details.route)
    #expect(package.tlsFingerprint == details.fingerprint)
    let wrongCode = details.code == "012345" ? "012346" : "012345"
    await #expect(throws: PairingJoinCodeError.rejected) {
        try await redeemer.redeem(code: wrongCode, route: details.route)
    }
    await #expect(throws: PairingJoinCodeError.certificateMismatch) {
        try await redeemer.redeem(code: details.code, route: details.wrongPinRoute)
    }
    try Data("passed".utf8).write(
        to: directory.appendingPathComponent("https.done"),
        options: .atomic
    )
}

private struct HTTPSInterop: Decodable {
    let route: URL
    let wrongPinRoute: URL
    let code: String
    let fingerprint: String
}
