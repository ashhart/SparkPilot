import CryptoKit
import Foundation
import Network
import SparkAPI
import SparkAppComposition
import SparkDiscovery
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing

// MARK: - Discovered service URL derivation

// Verifies discovered routes against exact hosts and advertised ports under the implementation's platform guard.
#if os(macOS)

    @Test func anUnresolvedServiceEndpointHasNoRoute() {
        // An unresolved service endpoint cannot produce a URL by guessing its hostname or port.
        let spark = DiscoveredSpark(
            id: "1",
            displayName: "Spark",
            endpoint: .service(
                name: "Spark-ab12cd34._spark-runtime._tcp",
                type: "_spark-runtime._tcp",
                domain: "local.",
                interface: nil
            ),
            interface: nil,
            shortNodeID: "ab12cd34"
        )
        #expect(spark.runtimeRoute() == nil)
    }

    @Test func aResolvedEndpointKeepsTheAdvertisedHostAndPort() {
        let spark = DiscoveredSpark(
            id: "1",
            displayName: "Spark",
            endpoint: .hostPort(host: .name("spark-ab12cd34.local", nil), port: 8443),
            interface: nil,
            shortNodeID: "ab12cd34"
        )
        #expect(
            spark.runtimeRoute()?.absoluteString == "https://spark-ab12cd34.local:8443",
            "the advertised port is used, not a hardcoded 7443"
        )
    }

    @Test func aResolvedIPv4EndpointBecomesALiteralRoute() {
        let spark = DiscoveredSpark(
            id: "1",
            displayName: "Spark",
            endpoint: .hostPort(host: .ipv4(.init("192.168.1.44")!), port: 7443),
            interface: nil,
            shortNodeID: "ab12cd34"
        )
        #expect(spark.runtimeRoute()?.absoluteString == "https://192.168.1.44:7443")
    }

    @Test func aLinkLocalIPv6EndpointKeepsItsScopeInBrackets() {
        // Preserve and URL-encode IPv6 link-local interface zones.
        let host = NWEndpoint.Host("fe80::1%en0")
        let spark = DiscoveredSpark(
            id: "1",
            displayName: "Spark",
            endpoint: .hostPort(host: host, port: 7443),
            interface: nil,
            shortNodeID: "ab12cd34"
        )
        let route = try? #require(spark.runtimeRoute())
        #expect(route?.port == 7443)
        #expect(route?.absoluteString.contains("%25en0") == true, "the zone is percent-encoded")
    }

#endif
