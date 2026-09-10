import CryptoKit
import Foundation

/// Encode SHA-256 digests consistently as lowercase hexadecimal.
public enum SHA256Hex {
    public static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
