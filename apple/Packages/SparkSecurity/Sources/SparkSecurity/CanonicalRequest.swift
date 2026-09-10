import CryptoKit
import Foundation

/// SPARK2 canonical request signing (§37.1, §58.3).
public struct CanonicalRequest: Equatable, Sendable {
    public let method: String
    public let pathAndQuery: String
    public let timestamp: String
    public let nonce: String
    public let bodyHashHex: String
    public let deviceID: String
    public let nodeID: UUID

    public init(
        method: String,
        pathAndQuery: String,
        timestamp: String,
        nonce: String,
        bodyHashHex: String,
        deviceID: String,
        nodeID: UUID
    ) {
        self.method = method
        self.pathAndQuery = pathAndQuery
        self.timestamp = timestamp
        self.nonce = nonce
        self.bodyHashHex = bodyHashHex
        self.deviceID = deviceID
        self.nodeID = nodeID
    }

    public var signatureInput: Data {
        Data(
            [
                "SPARK2",
                method.uppercased(),
                pathAndQuery,
                timestamp,
                nonce,
                bodyHashHex,
                deviceID,
                nodeID.uuidString.lowercased(),
            ]
            .joined(separator: "\n").utf8
        )
    }

    /// The request headers a signed request must carry (§58.3).
    public func headers(signingKey: (Data) throws -> Data) throws -> [String: String] {
        let signature = try signingKey(signatureInput)
        return [
            "X-Spark-Device-ID": deviceID,
            "X-Spark-Node-ID": nodeID.uuidString.lowercased(),
            "X-Spark-Timestamp": timestamp,
            "X-Spark-Nonce": nonce,
            "X-Spark-Content-SHA256": bodyHashHex,
            "X-Spark-Signature": Base64URL.encode(signature),
        ]
    }
}

public enum SHA256Digest {
    /// Lowercase hex SHA-256 over the exact bytes transmitted.
    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var base64 =
            text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

/// CSPRNG nonce per §37.3.
public enum SecureRandom {
    public static func nonce(byteCount: Int = 24) throws -> Data {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw SecurityRandomError.failed(status)
        }
        return data
    }
}

public enum SecurityRandomError: Error {
    case failed(OSStatus)
}
