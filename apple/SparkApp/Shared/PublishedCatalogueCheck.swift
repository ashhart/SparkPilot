import CryptoKit
import Foundation

/// Compare the published catalogue with the runtime using SHA-256 of the raw bytes.
public struct PublishedCatalogueCheck: Equatable, Sendable {
    public let bytes: Data
    public let digest: String
    public let recipeCount: Int
    public let checkedAt: Date

    /// A file that is not a catalogue is refused here; the Spark would refuse it too, but later and less clearly.
    public init(bytes: Data, checkedAt: Date = Date()) throws {
        guard bytes.count >= 2,
            let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let recipes = object["recipes"] as? [Any], object["signature"] != nil
        else { throw PublishedCatalogueCheckError.notACatalogue }
        self.bytes = bytes
        self.digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        self.recipeCount = recipes.count
        self.checkedAt = checkedAt
    }

    /// Different bytes from the Spark's verified snapshot: there is something to review.
    public func differs(from currentDigest: String?) -> Bool {
        guard let currentDigest else { return true }
        return digest != currentDigest.lowercased()
    }
}

public enum PublishedCatalogueCheckError: Error, Equatable {
    case notACatalogue
}
