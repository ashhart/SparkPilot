import Foundation
import SparkCore
import Testing
@testable import SparkLibrary

@Test func retiringAPublicRoutePreservesTheSparkAndItsPrivateRoutes() throws {
    let node = SparkNodeID(rawValue: UUID())
    let route = CachedRoute(baseURL: URL(string: "https://100.96.4.2:7443")!, kind: .privateOverlay)
    let original = LibraryEntry(
        logicalKey: .node(node),
        name: "Family Spark",
        customLabel: "Granddad’s Spark",
        members: [
            LibraryMember(
                nodeID: node,
                name: "Family Spark",
                role: .standalone,
                authorityFingerprint: "paired-authority",
                routes: [route],
                reachable: true
            )
        ]
    )
    let encoded = try JSONEncoder().encode(original)
    var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var members = try #require(payload["members"] as? [[String: Any]])
    let routes = try #require(members[0]["routes"] as? [[String: Any]])
    var retired = routes[0]
    retired["kind"] = "cloudflarePublic"
    retired["baseURL"] = "https://retired.example"
    members[0]["routes"] = [retired] + routes
    payload["members"] = members
    payload["cachedOperationalSnapshot"] = ["preferredRoute": ["kind": "cloudflarePublic"]]

    let recovered = try LibraryPayloadMigration.decode(
        JSONSerialization.data(withJSONObject: payload)
    )
    #expect(recovered.id == original.id)
    #expect(recovered.customLabel == original.customLabel)
    #expect(recovered.members[0].authorityFingerprint == "paired-authority")
    #expect(recovered.members[0].routes == [route])
    #expect(recovered.cachedOperationalSnapshot == nil)
    #expect(recovered.connectionState == .offlineCached)
    let roundTrip = try LibraryPayloadMigration.decode(JSONEncoder().encode(recovered))
    #expect(roundTrip == recovered)

    members[0]["routes"] = [retired]
    payload["members"] = members
    let offline = try LibraryPayloadMigration.decode(
        JSONSerialization.data(withJSONObject: payload)
    )
    #expect(offline.id == original.id)
    #expect(offline.members[0].routes.isEmpty)
    #expect(!offline.members[0].reachable)
}

@Test func routeRetirementDoesNotHideCorruptionInASupportedRoute() throws {
    let node = SparkNodeID(rawValue: UUID())
    let original = LibraryEntry(
        logicalKey: .node(node),
        name: "Spark",
        members: [
            LibraryMember(
                nodeID: node,
                name: "Spark",
                role: .standalone,
                routes: [
                    CachedRoute(baseURL: URL(string: "https://spark.local:7443")!, kind: .localWiFi)
                ]
            )
        ]
    )
    let data = try JSONEncoder().encode(original)
    let damaged = Data(
        String(decoding: data, as: UTF8.self).replacingOccurrences(
            of: "localWiFi",
            with: "unknownRoute"
        ).utf8
    )
    #expect(throws: DecodingError.self) { try LibraryPayloadMigration.decode(damaged) }
}
