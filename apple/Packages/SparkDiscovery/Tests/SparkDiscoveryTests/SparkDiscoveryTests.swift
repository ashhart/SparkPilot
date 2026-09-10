import Foundation
import Network
import Testing
@testable import SparkDiscovery

@MainActor
@Test func legacyDiscoveryInitializerRetainsItsZeroArgumentFunctionType() {
    let initializer: @MainActor () -> SparkDiscoveryService = SparkDiscoveryService.init
    _ = initializer
}

/// Deduplicate advertisements by identity hint across network interfaces.
@Test func duplicateAdvertisementsMergeByNodeID() {
    var merger = DiscoveryMerger()
    let now = Date()

    let wifi = NodeAdvertisement(
        instance: "Alex's Spark-7a836150",
        endpoint: .service(
            name: "Alex's Spark-7a836150",
            type: "_spark-runtime._tcp",
            domain: "local.",
            interface: nil
        ),
        interfaceKind: .wifi,
        txt: NodeTXT(raw: "api=1\nnode=7a836150\ncluster=none\nrole=standalone"),
        discoveredAt: now
    )
    let wired = NodeAdvertisement(
        instance: "Alex's Spark-7a836150",
        endpoint: .service(
            name: "Alex's Spark-7a836150",
            type: "_spark-runtime._tcp",
            domain: "local.",
            interface: nil
        ),
        interfaceKind: .wiredEthernet,
        txt: NodeTXT(raw: "api=1\nnode=7a836150\ncluster=none\nrole=standalone"),
        discoveredAt: now.addingTimeInterval(1)
    )

    let after = merger.upsert(wifi)
    #expect(after.count == 1)
    let afterWired = merger.upsert(wired)
    #expect(afterWired.count == 1, "same secure identity remains one node")
    #expect(afterWired.first?.interfaceKind == .wiredEthernet, "newest advertisement wins")
}

/// Distinct nodes remain distinct entries.
@Test func distinctNodesRemainDistinct() {
    var merger = DiscoveryMerger()
    let a = NodeAdvertisement(
        instance: "A",
        endpoint: .service(
            name: "A",
            type: "_spark-runtime._tcp",
            domain: "local.",
            interface: nil
        ),
        interfaceKind: .wifi,
        txt: NodeTXT(raw: "node=11111111"),
        discoveredAt: Date()
    )
    let b = NodeAdvertisement(
        instance: "B",
        endpoint: .service(
            name: "B",
            type: "_spark-runtime._tcp",
            domain: "local.",
            interface: nil
        ),
        interfaceKind: .wifi,
        txt: NodeTXT(raw: "node=22222222"),
        discoveredAt: Date()
    )
    _ = merger.upsert(a)
    let after = merger.upsert(b)
    #expect(after.count == 2)
}

/// Wired advertisements are recognised as direct-link candidates.
@Test func interfaceVectorizationDistinguishesWired() {
    let ad = NodeAdvertisement(
        instance: "wired-node",
        endpoint: .service(
            name: "wired-node",
            type: "_spark-runtime._tcp",
            domain: "local.",
            interface: nil
        ),
        interfaceKind: .wiredEthernet,
        txt: NodeTXT(raw: "node=abcdef01")
    )
    #expect(ad.isWired)
}

@MainActor
@Test func discoveryServiceUsesInjectedAdvertisementTime() {
    let discoveredAt = Date(timeIntervalSince1970: 1_790_000_000)
    let service = SparkDiscoveryService(now: { discoveredAt })
    let advertisement = service.makeAdvertisement(
        instance: "clocked-node",
        endpoint: .service(
            name: "clocked-node",
            type: "_spark-runtime._tcp",
            domain: "local.",
            interface: nil
        ),
        interfaceKind: .wifi,
        txt: NodeTXT(raw: "node=12345678")
    )

    #expect(advertisement.discoveredAt == discoveredAt)
}

@Test func quickStartParserReadsStandardWiFiCode() throws {
    let credentials = try QuickStartCodeParser.parse(
        #"WIFI:T:WPA;S:DGX\;Spark\:A1B2;P:correct\;horse\:battery;;"#
    )

    #expect(credentials.exactSSID == "DGX;Spark:A1B2")
    #expect(credentials.passphrase == "correct;horse:battery")
    #expect(credentials.setupPage == nil)
    #expect(!credentials.debugDescription.contains(credentials.passphrase))
}

@Test func quickStartParserReadsSparkSetupURL() throws {
    let credentials = try QuickStartCodeParser.parse(
        "spark://setup?ssid=DGX-Spark-A1B2&password=correct-horse&page=http%3A%2F%2F192.168.55.1%2Fsetup"
    )

    #expect(credentials.exactSSID == "DGX-Spark-A1B2")
    #expect(credentials.passphrase == "correct-horse")
    #expect(credentials.setupPage == URL(string: "http://192.168.55.1/setup"))
}

@Test func quickStartParserRejectsUnsafeOrIncompleteCodes() {
    #expect(throws: QuickStartCodeError.self) {
        try QuickStartCodeParser.parse("WIFI:T:nopass;S:DGX-Spark;;")
    }
    #expect(throws: QuickStartCodeError.self) {
        try QuickStartCodeParser.parse("spark://setup?ssid=DGX-Spark")
    }
    #expect(throws: QuickStartCodeError.self) {
        try QuickStartCodeParser.parse(
            "spark://setup?ssid=DGX-Spark&password=correct-horse&page=file:///etc/passwd"
        )
    }
}

/// The Quick Start `page` is attacker-printable, so only setup-network hosts may receive the password.
@Test func setupPageAddressAcceptsOnlySetupNetworkHosts() {
    let accepted = [
        "http://192.168.55.1/setup", "http://10.0.0.5", "https://172.31.4.2:443/",
        "http://169.254.1.1:80/setup", "http://[fe80::1%25en0]/", "https://[fd12:3456::1]/",
        "http://spark-a1b2.local", "HTTP://DGX-Spark-A1B2.LOCAL/setup",
    ]
    for page in accepted {
        #expect(SetupPageAddress.isOnSetupNetwork(URL(string: page)!), "\(page)")
    }
    let refused = [
        "http://evil.example/", "https://8.8.8.8/", "http://172.32.0.1/", "http://[2001:db8::1]/",
        "http://127.0.0.1/", "http://localhost/", "http://spark.example.local/",
        "http://spark-a1b2.local:8080/", "http://user@192.168.55.1/", "file:///etc/passwd",
        "ftp://192.168.55.1/", "http:///setup",
    ]
    for page in refused {
        #expect(!SetupPageAddress.isOnSetupNetwork(URL(string: page)!), "\(page)")
    }
}

@Test func quickStartParserRefusesAPublicSetupPage() {
    #expect(throws: QuickStartCodeError.invalidCredentials(.unsupportedSetupURL)) {
        try QuickStartCodeParser.parse(
            "spark://setup?ssid=DGX-Spark-A1B2&password=correct-horse&page=http%3A%2F%2Fevil.example%2F"
        )
    }
    #expect(throws: SetupNetworkCredentialError.unsupportedSetupURL) {
        try SetupNetworkCredentials(
            ssid: "DGX-Spark-A1B2",
            passphrase: "correct-horse",
            setupPage: URL(string: "https://203.0.113.9/")
        )
    }
}

@Test func bootstrapCandidateKeepsOnlyPublicDiscoveryData() {
    let endpoint = NWEndpoint.service(
        name: "spark-a1b2",
        type: "_ssh._tcp",
        domain: "local.",
        interface: nil
    )
    let candidate = BootstrapSpark(displayName: "spark-a1b2", endpoint: endpoint)

    #expect(candidate.displayName == "spark-a1b2")
    #expect(candidate.id.contains("spark-a1b2"))
}

/// Expire stale advertisements so discovery does not retain dead endpoints.
@Test func staleAdvertisementsAreDropped() {
    var merger = DiscoveryMerger()
    let old = NodeAdvertisement(
        instance: "old",
        endpoint: .service(
            name: "old",
            type: "_spark-runtime._tcp",
            domain: "local.",
            interface: nil
        ),
        interfaceKind: .other,
        txt: NodeTXT(raw: "node=aaaaaaaa"),
        discoveredAt: Date(timeIntervalSinceNow: -60)
    )
    _ = merger.upsert(old)
    merger.removeStale(olderThan: 30, now: Date())
    #expect(merger.count == 0)
}

/// TXT parsing matches the §12.1 contract keys.
@Test func txtParsingExtractsContractKeys() {
    let txt = NodeTXT(
        raw:
            "api=1\nnode=7a836150\ncluster=none\npairing=closed\nrole=standalone\ntls=t9lNEpIu\nruntime=0.1.0"
    )
    #expect(txt.api == "1")
    #expect(txt.node == "7a836150")
    #expect(txt.cluster == "none")
    #expect(txt.pairing == "closed")
    #expect(txt.role == "standalone")
    #expect(txt.tls == "t9lNEpIu")
    #expect(txt.runtime == "0.1.0")
}

/// Verify that the shipping NWBrowser forwards TXT bytes into the shared advertisement parser.
@Test func bonjourMetadataReachesTheDiscoveryIdentityHint() {
    let metadata = NWBrowser.Result.Metadata.bonjour(
        NWTXTRecord([
            "api": "1",
            "node": "7a836150",
            "cluster": "none",
            "pairing": "closed",
            "role": "standalone",
            "tls": "t9lNEpIu",
            "runtime": "0.1.0",
        ])
    )

    let txt = NodeTXT(metadata: metadata)

    #expect(txt.node == "7a836150")
    #expect(txt.tls == "t9lNEpIu")
    #expect(txt.runtime == "0.1.0")
}

@Test func missingBonjourMetadataDoesNotInventAnIdentityHint() {
    let txt = NodeTXT(metadata: .none)

    #expect(txt.node == nil)
    #expect(txt.tls == nil)
}

/// Denied permission must map to a recovery path, not a dead end.
@Test func deniedPermissionProducesRecoveryUI() {
    let recovery = PermissionRecovery(state: .denied)
    #expect(recovery.title.contains("Local Network"))
    #expect(recovery.actionLabel == "Open Settings")
    #expect(recovery.action == .openApplicationSettings)

    let restricted = PermissionRecovery(state: .restricted)
    #expect(restricted.actionLabel == "Review Restrictions")
    #expect(restricted.action == .reviewRestrictions)
}

// MARK: - Setup-network selection (§10.8.3, §11.2)

@Test func partialNetworkNameBecomesAPrefixRequestTheSystemCanPresent() throws {
    let credentials = try SetupNetworkCredentials(
        ssidPrefix: "spark",
        passphrase: "correct-horse"
    )

    #expect(credentials.match == .ssidPrefix("spark"))
    #expect(credentials.exactSSID == nil, "a prefix is not a network name")
    #expect(credentials.match.matches("spark-a1b2"))
    #expect(credentials.match.matches("Spark-A1B2"), "SSID casing must not exclude a match")
    #expect(!credentials.match.matches("home-wifi"))
}

@Test func exactNetworkNameMatchesOnlyThatNetwork() throws {
    let credentials = try SetupNetworkCredentials(
        ssid: "spark-a1b2",
        passphrase: "correct-horse"
    )

    #expect(credentials.exactSSID == "spark-a1b2")
    #expect(credentials.match.matches("SPARK-A1B2"))
    #expect(!credentials.match.matches("spark-a1b2-guest"))
}

@Test func prefixRequestsTheSystemWouldRejectAreRefusedWithAReason() {
    #expect(throws: SetupNetworkCredentialError.ssidPrefixTooShort) {
        try SetupNetworkCredentials(ssidPrefix: "sp", passphrase: "correct-horse")
    }
    #expect(throws: SetupNetworkCredentialError.ssidPrefixTooLong) {
        try SetupNetworkCredentials(
            ssidPrefix: String(repeating: "s", count: 33),
            passphrase: "correct-horse"
        )
    }
    #expect(throws: SetupNetworkCredentialError.invalidPassphrase) {
        try SetupNetworkCredentials(ssidPrefix: "spark", passphrase: "short")
    }
}

@Test func prefixCredentialsStillRedactTheirPassphrase() throws {
    let credentials = try SetupNetworkCredentials(
        ssidPrefix: "spark",
        passphrase: "correct-horse"
    )

    #expect(!credentials.debugDescription.contains("correct-horse"))
    #expect(credentials.debugDescription.contains("<redacted>"))
}

/// Counts how many times the system was actually asked, from the main actor the readers run on.
@MainActor
final class WiFiAuthorizationRequestCounter {
    var count = 0
}

/// BH-44: two overlapping SSID reads used to overwrite one continuation slot and hang the first.
@MainActor
@Test func twoOverlappingWiFiReadsShareOneAuthorizationRequest() async {
    let gate = WiFiAuthorizationGate()
    let counter = WiFiAuthorizationRequestCounter()
    let first = Task { @MainActor in await gate.wait { counter.count += 1 } }
    let second = Task { @MainActor in await gate.wait { counter.count += 1 } }
    var spins = 0
    while gate.waitingCount < 2, spins < 10_000 {
        await Task.yield()
        spins += 1
    }
    #expect(gate.waitingCount == 2, "the second read replaced the first")
    gate.resolve(true)
    #expect(await first.value, "the first read was never answered")
    #expect(await second.value)
    #expect(counter.count == 1, "the owner was asked twice for one permission")
}

@MainActor
@Test func aReadAfterTheAnswerAsksAgainRatherThanReusingAFinishedWait() async {
    let gate = WiFiAuthorizationGate()
    let counter = WiFiAuthorizationRequestCounter()
    let first = Task { @MainActor in await gate.wait { counter.count += 1 } }
    var spins = 0
    while gate.waitingCount < 1, spins < 10_000 {
        await Task.yield()
        spins += 1
    }
    gate.resolve(false)
    #expect(await first.value == false)
    let second = Task { @MainActor in await gate.wait { counter.count += 1 } }
    spins = 0
    while gate.waitingCount < 1, spins < 10_000 {
        await Task.yield()
        spins += 1
    }
    gate.resolve(true)
    #expect(await second.value)
    #expect(counter.count == 2)
    #expect(gate.waitingCount == 0)
}
