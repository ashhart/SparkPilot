import Foundation
import Observation

public enum NativeSparkSetupStep: Int, CaseIterable, Sendable, Equatable {
    case region
    case licence
    case account
    case privacy
    case wifi
    case connecting
}

@MainActor
@Observable
public final class NativeSparkSetupModel {
    public var step: NativeSparkSetupStep = .region
    public private(set) var languages: [SparkOOBELanguage] = []
    public private(set) var timeZones: [String] = []
    public var selectedLanguageIndex: Int?
    public var selectedTimeZoneIndex: Int?
    public private(set) var licenceText = ""
    public var hasAcceptedLicence = false
    public var username = ""
    public var password = ""
    public var confirmPassword = ""
    public var functionalTelemetry = false
    public var technicalTelemetry = false
    public var networks: [SparkOOBEWiFiNetwork] = []
    public private(set) var ethernetHasInternet = false
    public var selectedNetworkIndex: Int?
    public var wifiPassword = ""
    public private(set) var isWorking = false
    public private(set) var errorMessage: String?
    /// Shown beside the password and Wi-Fi fields when the first-boot page is plain HTTP.
    public let transportNotice: String?

    @ObservationIgnored
    private let service: any SparkOOBEServicing
    @ObservationIgnored
    private let localeIdentifier: String
    @ObservationIgnored
    private let timeZoneIdentifier: String
    @ObservationIgnored
    private let onAccountCreated: @MainActor (String, String) -> Void
    @ObservationIgnored
    private let onWiFiSubmitted: @MainActor () -> Void
    @ObservationIgnored
    private var hasLoaded = false

    public init(
        service: any SparkOOBEServicing,
        localeIdentifier: String = Locale.current.identifier,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        transportNotice: String? = nil,
        onAccountCreated: @escaping @MainActor (String, String) -> Void = { _, _ in },
        onWiFiSubmitted: @escaping @MainActor () -> Void = {}
    ) {
        self.service = service
        self.localeIdentifier = localeIdentifier
        self.timeZoneIdentifier = timeZoneIdentifier
        self.transportNotice = transportNotice
        self.onAccountCreated = onAccountCreated
        self.onWiFiSubmitted = onWiFiSubmitted
    }

    public func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await perform {
            let loadedOptions = try await service.regionalOptions()
            languages = loadedOptions.languages
            timeZones = loadedOptions.timeZones
            selectDefaults()
        }
    }

    public func continueSetup() async {
        switch step {
        case .region:
            guard let selectedLanguageIndex, let selectedTimeZoneIndex else { return }
            await perform {
                try await service.configureRegion(
                    languageIndex: selectedLanguageIndex,
                    timeZoneIndex: selectedTimeZoneIndex
                )
                licenceText = try await service.licenceText()
                step = .licence
            }
        case .licence:
            guard hasAcceptedLicence else { return }
            await perform {
                try await service.acceptLicence()
                step = .account
            }
        case .account:
            guard accountIsValid else { return }
            let submittedUsername = username
            let submittedPassword = password
            await perform {
                defer {
                    password = ""
                    confirmPassword = ""
                }
                try await service.createAccount(
                    username: submittedUsername,
                    password: submittedPassword
                )
                // Hand the session credential to the outer flow before clearing native setup fields to avoid a second password prompt.
                onAccountCreated(submittedUsername, submittedPassword)
                step = .privacy
            }
        case .privacy:
            await perform {
                try await service.configureTelemetry(
                    functional: functionalTelemetry,
                    technical: technicalTelemetry
                )
                let options = try await service.networkOptions()
                ethernetHasInternet = options.ethernetHasInternet
                networks = options.wifiNetworks
                selectedNetworkIndex = nil
                step = .wifi
            }
        case .wifi:
            if ethernetHasInternet, selectedNetworkIndex == nil {
                step = .connecting
                onWiFiSubmitted()
                return
            }
            guard let selectedNetworkIndex,
                let network = networks.first(where: { $0.index == selectedNetworkIndex }),
                !network.isProtected || !wifiPassword.isEmpty
            else { return }

            let selectedSSID = network.ssid
            let submittedPassword = wifiPassword
            await perform {
                defer { wifiPassword = "" }
                let refreshedNetworks = try await service.wifiNetworks()
                networks = refreshedNetworks
                guard
                    let refreshedNetwork =
                        refreshedNetworks
                        .filter({ $0.ssid == selectedSSID })
                        .max(by: { $0.strength < $1.strength })
                else {
                    self.selectedNetworkIndex = nil
                    errorMessage =
                        String(
                            localized:
                                "That Wi-Fi network is no longer visible to your Spark. Check the connection and choose it again."
                        )
                    return
                }

                self.selectedNetworkIndex = refreshedNetwork.index
                try await service.connectWiFi(
                    index: refreshedNetwork.index,
                    password: submittedPassword
                )
                step = .connecting
                onWiFiSubmitted()
            }
        case .connecting:
            break
        }
    }

    public func refreshNetworks() async {
        await perform {
            let options = try await service.networkOptions()
            ethernetHasInternet = options.ethernetHasInternet
            networks = options.wifiNetworks
            if !networks.contains(where: { $0.index == selectedNetworkIndex }) {
                selectedNetworkIndex = nil
                wifiPassword = ""
            }
        }
    }

    public var selectedNetwork: SparkOOBEWiFiNetwork? {
        guard let selectedNetworkIndex else { return nil }
        return networks.first(where: { $0.index == selectedNetworkIndex })
    }

    public func selectNetwork(_ network: SparkOOBEWiFiNetwork) {
        guard step == .wifi, networks.contains(network) else { return }
        selectedNetworkIndex = network.index
        wifiPassword = ""
        errorMessage = nil
    }

    public func chooseDifferentNetwork() {
        guard step == .wifi, !isWorking else { return }
        selectedNetworkIndex = nil
        wifiPassword = ""
        errorMessage = nil
    }

    public func retryNetworkSelection() {
        guard !isWorking else { return }
        errorMessage = nil
        wifiPassword = ""
        selectedNetworkIndex = nil
        ethernetHasInternet = false
        step = .wifi
    }

    public func goBack() {
        guard !isWorking else { return }
        errorMessage = nil
        switch step {
        case .licence:
            step = .region
        case .account:
            step = .licence
        case .privacy:
            step = .account
        case .wifi:
            if selectedNetworkIndex == nil {
                step = .privacy
            } else {
                chooseDifferentNetwork()
            }
        case .region, .connecting:
            break
        }
    }

    public var accountIsValid: Bool {
        let usernamePattern = /^[a-z][a-z0-9_-]*$/
        return username.wholeMatch(of: usernamePattern) != nil
            && password.count >= 6
            && password == confirmPassword
    }

    public var primaryActionIsDisabled: Bool {
        if isWorking { return true }
        switch step {
        case .region:
            return selectedLanguageIndex == nil || selectedTimeZoneIndex == nil
        case .licence:
            return !hasAcceptedLicence
        case .account:
            return !accountIsValid
        case .privacy:
            return false
        case .wifi:
            if ethernetHasInternet, selectedNetworkIndex == nil { return false }
            guard let selectedNetworkIndex,
                let network = networks.first(where: { $0.index == selectedNetworkIndex })
            else { return true }
            return network.isProtected && wifiPassword.isEmpty
        case .connecting:
            return true
        }
    }

    private func selectDefaults() {
        let normalizedLocale = localeIdentifier.replacingOccurrences(of: "-", with: "_")
        selectedLanguageIndex =
            languages.first(where: {
                $0.locale.replacingOccurrences(of: ".utf8", with: "") == normalizedLocale
            })?.index ?? languages.first?.index
        selectedTimeZoneIndex =
            timeZones.firstIndex(of: timeZoneIdentifier) ?? timeZones.indices.first
    }

    /// Maps setup failures to app-owned copy without displaying unauthenticated server response bodies.
    static func describe(_ error: SparkOOBEClientError) -> String {
        switch error {
        case .firmwareUpdateFailed:
            String(
                localized: """
                    Your Spark could not finish its firmware update. Leave it powered on \
                    and start setup again.
                    """
            )
        case .updateTimedOut:
            String(
                localized: """
                    Your Spark is taking longer than expected. Leave it powered on and \
                    start setup again.
                    """
            )
        case .invalidResponse, .decoding:
            String(
                localized: """
                    This app could not read your Spark's answer. Its software may be newer \
                    than this app.
                    """
            )
        case .server:
            String(
                localized: "Your Spark did not accept that change. Check the details and try again."
            )
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch let error as SparkOOBEClientError {
            errorMessage = Self.describe(error)
        } catch {
            errorMessage =
                String(
                    localized:
                        "Your Spark could not be reached. Stay connected to its Wi-Fi and try again."
                )
        }
    }
}
