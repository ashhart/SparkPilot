import CryptoKit
import Foundation

/// Pairing identity is separate from a route, which can change between Wi-Fi and Tailscale.
protocol SparkEventCursorIdentityProviding {
    var eventCursorIdentity: String { get }
}

/// Only replay positions are retained here; event payloads and connection addresses are never saved.
@MainActor
final class SparkEventCursorStore {
    static let shared = SparkEventCursorStore()
    private static let preferenceKey = "sparkpilot.events.cursors.v1"
    private static let maximumEntries = 128
    private let defaults: UserDefaults
    private let now: () -> Date

    private struct Entry: Codable {
        let cursor: String
        let updatedAt: Date
    }

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    static func scope(identity: String, pin: String) -> String {
        SHA256.hash(data: Data("SPARK-EVENT-CURSOR1\n\(identity)\n\(pin.lowercased())".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func cursor(for scope: String) -> String? { entries()[scope]?.cursor }

    func checkpoint(_ cursor: String?, for scope: String) {
        var values = entries()
        if let cursor, Self.valid(cursor) {
            values[scope] = Entry(cursor: cursor, updatedAt: now())
        } else {
            values[scope] = nil
        }
        let retained = values.sorted {
            if $0.value.updatedAt == $1.value.updatedAt { return $0.key < $1.key }
            return $0.value.updatedAt > $1.value.updatedAt
        }.prefix(Self.maximumEntries)
        guard
            let encoded = try? JSONEncoder().encode(
                Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
            )
        else { return }
        defaults.set(encoded, forKey: Self.preferenceKey)
    }

    private func entries() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.preferenceKey), data.count <= 65_536,
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded.filter { key, entry in
            key.count == 64 && key.allSatisfy(\.isHexDigit) && Self.valid(entry.cursor)
        }
    }

    private static func valid(_ cursor: String) -> Bool {
        !cursor.isEmpty && cursor.utf8.count <= 19
            && cursor.utf8.allSatisfy { (48...57).contains($0) }
            && Int64(cursor).map { $0 >= 0 } == true
    }
}
