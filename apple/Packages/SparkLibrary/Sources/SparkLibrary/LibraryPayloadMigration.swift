import Foundation

/// Discard retired route records without losing the saved Spark, cluster membership or local label.
enum LibraryPayloadMigration {
    static func decode(_ data: Data) throws -> LibraryEntry {
        guard var entry = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var members = entry["members"] as? [[String: Any]]
        else {
            return try JSONDecoder().decode(LibraryEntry.self, from: data)
        }
        var changed = false
        for index in members.indices {
            guard let routes = members[index]["routes"] as? [[String: Any]] else { continue }
            let kept = routes.filter { $0["kind"] as? String != "cloudflarePublic" }
            if kept.count != routes.count {
                members[index]["routes"] = kept
                members[index]["reachable"] = false
                changed = true
            }
        }
        if let snapshot = entry["cachedOperationalSnapshot"] as? [String: Any] {
            for key in ["preferredRoute", "routeInUse"] {
                if let route = snapshot[key] as? [String: Any],
                    route["kind"] as? String == "cloudflarePublic"
                {
                    changed = true
                }
            }
        }
        guard changed else { return try JSONDecoder().decode(LibraryEntry.self, from: data) }
        entry["members"] = members
        entry.removeValue(forKey: "cachedOperationalSnapshot")
        entry["connectionState"] = "offlineCached"
        return try JSONDecoder().decode(
            LibraryEntry.self,
            from: JSONSerialization.data(withJSONObject: entry)
        )
    }
}
