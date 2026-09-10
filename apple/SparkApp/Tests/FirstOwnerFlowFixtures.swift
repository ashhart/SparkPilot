import Foundation
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkSecurity
import Testing

@testable import SparkAppComposition

/// Exercises onboarding through install and pairing, including identity rejection, claim refusal and persistent device keys.

// MARK: - Doubles

let firstOwnerFlowTestNodeID = "ca890ed7-7c8c-4b2c-9218-b77ef24f569a"

let firstOwnerFlowTestTlsFingerprint = String(repeating: "a", count: 64)

// Use the actual SHA-256 authority fingerprint for the fixture's all-0xcc public key so trust validation remains real.
let firstOwnerFlowTestAuthorityFingerprint =
    "c2f480d4dda9f4522b9f6d590011636d904accfe59f12f9d66a0221c2558e3a2"

@MainActor
final class FirstOwnerFlowTestHomeWiFiReader: CurrentWiFiNetworkReading {
    func currentSSID() async -> String? { "Home WiFi" }
}

func firstOwnerFlowTestBootstrapResult() -> RuntimeBootstrapResult {
    RuntimeBootstrapResult(
        nodeID: firstOwnerFlowTestNodeID,
        nodeName: "spark-a1b2",
        authorityFingerprint: firstOwnerFlowTestAuthorityFingerprint,
        authorityPublicKey: String(repeating: "c", count: 64),
        tlsFingerprint: firstOwnerFlowTestTlsFingerprint,
        invitationExpiresAt: "2099-01-01T00:00:00Z",
        invitation: .object(["role": .string("owner")]),
        trustRootSource: .supplied
    )
}

actor FirstOwnerFlowTestFakeInstaller: RuntimeBootstrapInstalling {
    private(set) var receivedPassword: String?
    private(set) var callCount = 0
    private let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func install(
        on target: BootstrapSpark,
        administratorPassword: String
    ) async throws -> RuntimeBootstrapResult {
        callCount += 1
        receivedPassword = administratorPassword
        if let failure { throw failure }
        return firstOwnerFlowTestBootstrapResult()
    }

    /// The Spark answers its survey at once: these flows start after the first-boot restart.
    func preflight(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String
    ) async throws -> HostPreflight {
        HostPreflight(survey: HostSurvey.parse("survey=1\nos=DGX OS 7.2\n"))
    }
}

actor FirstOwnerFlowTestFakePairingService: FirstOwnerPairingServicing {
    private(set) var receivedRoute: URL?
    private(set) var callCount = 0
    private let failure: (any Error)?

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    func claim(_ bootstrap: RuntimeBootstrapResult, route: URL) async throws -> NodeTrust {
        callCount += 1
        receivedRoute = route
        if let failure { throw failure }
        return NodeTrust(
            nodeID: bootstrap.nodeID,
            nodeName: bootstrap.nodeName,
            tlsFingerprint: bootstrap.tlsFingerprint,
            authorityFingerprint: bootstrap.authorityFingerprint,
            authorityPublicKey: bootstrap.authorityPublicKey,
            pairedAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
    }
}

@MainActor
final class FirstOwnerFlowTestFakeNetworkJoiner: SetupNetworkJoining {
    var canJoinSetupNetwork = true

    @discardableResult
    func join(_ credentials: SetupNetworkCredentials) async throws -> String {
        credentials.exactSSID ?? "spark-a1b2"
    }

    func forget(ssid: String) {}
}

actor FirstOwnerFlowTestFakeOOBEFinisher: SparkOOBEServicing {
    private(set) var didFinish = false

    func regionalOptions() async throws -> SparkOOBERegionalOptions {
        SparkOOBERegionalOptions(languages: [], timeZones: [])
    }
    func configureRegion(languageIndex: Int, timeZoneIndex: Int) async throws {}
    func licenceText() async throws -> String { "" }
    func acceptLicence() async throws {}
    func createAccount(username: String, password: String) async throws {}
    func configureTelemetry(functional: Bool, technical: Bool) async throws {}
    func wifiNetworks() async throws -> [SparkOOBEWiFiNetwork] { [] }
    func connectWiFi(index: Int, password: String) async throws {}
    func finishSetup() async throws { didFinish = true }
}

actor FirstOwnerFlowTestReadinessRuntime: SparkRuntimeReading {
    private let features: [String: Bool]

    init(
        containerRuntime: Bool = true,
        signedCatalogue: Bool = true,
        optionalServices: Bool = false
    ) {
        features = [
            "container_runtime": containerRuntime,
            "signed_catalogue": signedCatalogue,
            "optional_service_recipes": optionalServices,
            "open_webui_service": optionalServices,
        ]
    }

    func capabilities(route: URL) async throws -> SparkCapabilities {
        SparkCapabilities(apiVersion: 1, features: features)
    }

    func health(route: URL) async throws -> Health {
        try firstOwnerFlowTestReadinessDecode(
            #"{"api_version":1,"node_id":"ca890ed7-7c8c-4b2c-9218-b77ef24f569a","runtime_version":"0.1.0","status":"ok"}"#
        )
    }

    func status(route: URL) async throws -> SparkStatus {
        throw PendingRuntimeError.unconfigured
    }

    func models(route: URL) async throws -> ModelCatalogue {
        try firstOwnerFlowTestReadinessDecode(
            #"{"items":[{"id":"qwen/qwen3-0.6b-starter","display_name":"Qwen3 0.6B Starter","description":"Starter","recipe_revision":"r1","source_revision":"s1","install_state":"available","total_bytes":1600000000,"capabilities":{"chat":true},"fit":"ready","profiles":[]}],"next_cursor":null}"#
        )
    }

    func activeInference(route: URL) async throws -> ActiveInference {
        try firstOwnerFlowTestReadinessDecode(
            #"{"state":"unloaded","model_id":null,"profile_id":null,"context_length":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null}"#
        )
    }

    func openWebUIStatus(route: URL) async throws -> GeneratedAPI.OptionalServiceStatus {
        guard features["open_webui_service"] == true else {
            throw PendingRuntimeError.unconfigured
        }
        return .init(
            id: .openWebui,
            displayName: .openWebUI,
            state: .notInstalled,
            installed: false,
            running: false,
            healthy: false,
            installedImageDigest: nil,
            availableRevision: "open-webui-r1",
            availableVersion: "0.6.32",
            updateAvailable: false,
            accessPath: nil,
            accessPort: 7444,
            accessTls: true,
            inferenceGateway: .init(
                scopes: [.modelsRead, .chatCompletionsCreate],
                healthy: false,
                port: 18081,
                loopbackOnly: true
            ),
            recovery: nil
        )
    }
}

func firstOwnerFlowTestReadinessDecode<Value: Decodable>(_ json: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(json.utf8))
}

/// Drive the flow to `.runtimeInstall` with a bootstrap target in place.
@MainActor
struct FirstOwnerFlowTestUnavailableSignerError: Error {}

@MainActor
func firstOwnerFlowTestModelReadyToInstall(
    installer: any RuntimeBootstrapInstalling,
    pairingService: (any FirstOwnerPairingServicing)?,
    runtime: (any SparkRuntimeReading)? = nil,
    signerProvider: @escaping RetailOnboardingModel.SignerProvider = { firstOwnerFlowTestNodeID in
        SparkRequestSigner(
            deviceID: "test-device",
            nodeID: firstOwnerFlowTestNodeID,
            signingKey: SoftwareSigner()
        )
    }
) async -> RetailOnboardingModel {
    let service = FirstOwnerFlowTestFakeOOBEFinisher()
    let model = RetailOnboardingModel(
        networkJoiner: FirstOwnerFlowTestFakeNetworkJoiner(),
        currentWiFiReader: FirstOwnerFlowTestHomeWiFiReader(),
        runtimeInstaller: installer,
        pairingService: pairingService,
        oobeServiceFactory: { _ in service },
        runtime: runtime,
        signerProvider: signerProvider
    )
    model.startAddingSpark()
    model.setupSSID = "spark-a1b2"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    model.nativeSetupWiFiSubmitted()
    await model.networkHandoffChanged(.wifiAvailable)
    await model.bootstrapCandidatesChanged([
        BootstrapSpark(
            displayName: "spark-a1b2",
            endpoint: .hostPort(host: "spark-a1b2.local", port: 22)
        )
    ])
    // The Spark has restarted and answers again; the install step is next.
    await model.checkSparkIsBack()
    return model
}

/// Waits for retry task effects by yielding and bounded polling rather than assuming a fixed executor delay.
@MainActor
func firstOwnerFlowTestSettles(
    within timeout: Duration = .seconds(10),
    until condition: () async -> Bool
) async -> Bool {
    for _ in 0..<16 {
        if await condition() { return true }
        await Task.yield()
    }
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
