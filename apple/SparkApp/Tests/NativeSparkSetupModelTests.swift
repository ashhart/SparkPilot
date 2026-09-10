import Foundation
import Testing
@testable import SparkAppComposition

private actor FakeOOBEService: SparkOOBEServicing {
    private(set) var createdUsername: String?
    private(set) var createdPassword: String?
    private(set) var connectedIndex: Int?
    private(set) var connectedPassword: String?

    func regionalOptions() async throws -> SparkOOBERegionalOptions {
        SparkOOBERegionalOptions(
            languages: [
                SparkOOBELanguage(
                    index: 7,
                    countryCode: "GB",
                    languageCode: "en",
                    displayName: "English",
                    locale: "en_GB.utf8"
                )
            ],
            timeZones: ["UTC", "Europe/London"]
        )
    }

    func configureRegion(languageIndex: Int, timeZoneIndex: Int) async throws {}
    func licenceText() async throws -> String { "NVIDIA licence" }
    func acceptLicence() async throws {}

    func createAccount(username: String, password: String) async throws {
        createdUsername = username
        createdPassword = password
    }

    func configureTelemetry(functional: Bool, technical: Bool) async throws {}

    func wifiNetworks() async throws -> [SparkOOBEWiFiNetwork] {
        [SparkOOBEWiFiNetwork(index: 2, ssid: "Home", strength: 90, isProtected: true)]
    }

    func connectWiFi(index: Int, password: String) async throws {
        connectedIndex = index
        connectedPassword = password
    }

    func finishSetup() async throws {}
}

private actor LanguageOrderedOOBEService: SparkOOBEServicing {
    private var configuredRegion = false

    func regionalOptions() async throws -> SparkOOBERegionalOptions {
        SparkOOBERegionalOptions(
            languages: [
                SparkOOBELanguage(
                    index: 4,
                    countryCode: "GB",
                    languageCode: "en",
                    displayName: "English",
                    locale: "en_GB.utf8"
                )
            ],
            timeZones: ["Europe/London"]
        )
    }

    func configureRegion(languageIndex: Int, timeZoneIndex: Int) async throws {
        configuredRegion = true
    }

    func licenceText() async throws -> String {
        guard configuredRegion else {
            throw SparkOOBEClientError.server(
                statusCode: 409,
                diagnosticDetail: "Skipped Language Selection"
            )
        }
        return "NVIDIA licence"
    }

    func acceptLicence() async throws {}
    func createAccount(username: String, password: String) async throws {}
    func configureTelemetry(functional: Bool, technical: Bool) async throws {}
    func wifiNetworks() async throws -> [SparkOOBEWiFiNetwork] { [] }
    func connectWiFi(index: Int, password: String) async throws {}
    func finishSetup() async throws {}
}

private actor EthernetOOBEService: SparkOOBEServicing {
    private(set) var wifiWasConfigured = false

    func regionalOptions() async throws -> SparkOOBERegionalOptions {
        SparkOOBERegionalOptions(languages: [], timeZones: [])
    }
    func configureRegion(languageIndex: Int, timeZoneIndex: Int) async throws {}
    func licenceText() async throws -> String { "NVIDIA licence" }
    func acceptLicence() async throws {}
    func createAccount(username: String, password: String) async throws {}
    func configureTelemetry(functional: Bool, technical: Bool) async throws {}
    func networkOptions() async throws -> SparkOOBENetworkOptions {
        SparkOOBENetworkOptions(ethernetHasInternet: true, wifiNetworks: [])
    }
    func wifiNetworks() async throws -> [SparkOOBEWiFiNetwork] { [] }
    func connectWiFi(index: Int, password: String) async throws { wifiWasConfigured = true }
    func finishSetup() async throws {}
}

private actor ReorderedWiFiOOBEService: SparkOOBEServicing {
    private(set) var connectedIndex: Int?

    func regionalOptions() async throws -> SparkOOBERegionalOptions {
        SparkOOBERegionalOptions(languages: [], timeZones: [])
    }
    func configureRegion(languageIndex: Int, timeZoneIndex: Int) async throws {}
    func licenceText() async throws -> String { "NVIDIA licence" }
    func acceptLicence() async throws {}
    func createAccount(username: String, password: String) async throws {}
    func configureTelemetry(functional: Bool, technical: Bool) async throws {}
    func wifiNetworks() async throws -> [SparkOOBEWiFiNetwork] {
        [SparkOOBEWiFiNetwork(index: 9, ssid: "Home", strength: 94, isProtected: true)]
    }
    func connectWiFi(index: Int, password: String) async throws { connectedIndex = index }
    func finishSetup() async throws {}
}

@MainActor
@Test func nativeSetupSelectsThePhoneRegionByDefault() async {
    let model = NativeSparkSetupModel(
        service: FakeOOBEService(),
        localeIdentifier: "en_GB",
        timeZoneIdentifier: "Europe/London"
    )

    await model.load()

    #expect(model.step == .region)
    #expect(model.selectedLanguageIndex == 7)
    #expect(model.selectedTimeZoneIndex == 1)
}

@MainActor
@Test func nativeSetupSubmitsLanguageBeforeRequestingTheLicence() async {
    let model = NativeSparkSetupModel(
        service: LanguageOrderedOOBEService(),
        localeIdentifier: "en_GB",
        timeZoneIdentifier: "Europe/London"
    )

    await model.load()

    #expect(model.errorMessage == nil)
    #expect(model.selectedLanguageIndex == 4)
    #expect(model.selectedTimeZoneIndex == 0)
    #expect(!model.primaryActionIsDisabled)

    await model.continueSetup()

    #expect(model.step == .licence)
    #expect(model.licenceText == "NVIDIA licence")
}

@MainActor
@Test func nativeSetupClearsAccountPasswordsAfterSubmission() async {
    let service = FakeOOBEService()
    var createdUsername: String?
    var createdPassword: String?
    let model = NativeSparkSetupModel(
        service: service,
        onAccountCreated: {
            createdUsername = $0
            createdPassword = $1
        }
    )
    model.step = .account
    model.username = "alex"
    model.password = "correct-horse"
    model.confirmPassword = "correct-horse"

    await model.continueSetup()

    #expect(model.step == .privacy)
    #expect(model.password.isEmpty)
    #expect(model.confirmPassword.isEmpty)
    #expect(await service.createdUsername == "alex")
    #expect(await service.createdPassword == "correct-horse")
    #expect(createdUsername == "alex")
    #expect(createdPassword == "correct-horse")
}

@MainActor
@Test func nativeSetupClearsWiFiPasswordAndStartsHandoff() async {
    let service = FakeOOBEService()
    var handoffStarted = false
    let model = NativeSparkSetupModel(
        service: service,
        onWiFiSubmitted: { handoffStarted = true }
    )
    model.step = .wifi
    model.networks = [
        SparkOOBEWiFiNetwork(index: 2, ssid: "Home", strength: 90, isProtected: true)
    ]
    model.selectedNetworkIndex = 2
    model.wifiPassword = "home-secret"

    await model.continueSetup()

    #expect(model.step == .connecting)
    #expect(model.wifiPassword.isEmpty)
    #expect(handoffStarted)
    #expect(await service.connectedIndex == 2)
    #expect(await service.connectedPassword == "home-secret")
}

@MainActor
@Test func nativeSetupRefreshesTheSelectedNetworkIndexImmediatelyBeforeJoining() async {
    let service = ReorderedWiFiOOBEService()
    let model = NativeSparkSetupModel(service: service)
    model.step = .wifi
    model.networks = [
        SparkOOBEWiFiNetwork(index: 2, ssid: "Home", strength: 80, isProtected: true)
    ]
    model.selectedNetworkIndex = 2
    model.wifiPassword = "home-secret"

    await model.continueSetup()

    #expect(await service.connectedIndex == 9)
    #expect(model.step == .connecting)
}

@MainActor
@Test func backFromWiFiCredentialsReturnsToTheNetworkList() {
    let model = NativeSparkSetupModel(service: FakeOOBEService())
    model.step = .wifi
    model.networks = [
        SparkOOBEWiFiNetwork(index: 2, ssid: "Home", strength: 90, isProtected: true)
    ]
    model.selectedNetworkIndex = 2
    model.wifiPassword = "home-secret"

    model.goBack()

    #expect(model.step == .wifi)
    #expect(model.selectedNetworkIndex == nil)
    #expect(model.wifiPassword.isEmpty)
}

@MainActor
@Test func ethernetWithInternetSkipsWiFiCredentialsAndStartsHandoff() async {
    let service = EthernetOOBEService()
    var handoffStarted = false
    let model = NativeSparkSetupModel(
        service: service,
        onWiFiSubmitted: { handoffStarted = true }
    )
    model.step = .privacy

    await model.continueSetup()

    #expect(model.step == .wifi)
    #expect(model.ethernetHasInternet)
    #expect(!model.primaryActionIsDisabled)

    await model.continueSetup()

    #expect(model.step == .connecting)
    #expect(handoffStarted)
    #expect(!(await service.wifiWasConfigured))
}
