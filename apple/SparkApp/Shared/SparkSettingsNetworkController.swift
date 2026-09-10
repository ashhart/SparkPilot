import Foundation
import Observation
import CoreImage.CIFilterBuiltins
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkSecurity
import SwiftUI
@MainActor
@Observable
final class SparkSettingsNetworkController {
    private let runtime: any SparkSettingsManaging
    private let operations: SparkSettingsOperationCoordinator
    private let poller: SparkSettingsNetworkPoller
    private let networkPollAttempts: Int
    private let onKeptNetworkRoute: (@MainActor (URL, SparkIdentity) -> Void)?
    private var pendingNetworkIdentity: SparkIdentity?
    var snapshot: () -> GeneratedAPI.SparkSettingsSnapshot? = { nil }
    var wifi: () -> GeneratedAPI.WifiNetworksSnapshot? = { nil }
    var refresh: () async -> Void = {}
    var clearAllOptimisticState: () -> Void = {}
    var optimisticDirectEthernet: Bool?
    var optimisticTravelEnabled: Bool?
    private(set) var pendingNetworkChange: PendingSparkNetworkChange?

    var selectedWifiSSID: String?
    var wifiPassword = ""
    var revealsWifiPassword = false
    var travelSSID = ""
    var travelPassword = ""
    var revealsTravelPassword = false
    var lanAddress = ""
    var lanPrefixLength = 24
    var lanGateway = ""
    var lanDNSServers = ""

    init(
        runtime: any SparkSettingsManaging,
        operations: SparkSettingsOperationCoordinator,
        discovery: any SavedSparkRouteDiscovering,
        attempts: Int,
        delay: @escaping @Sendable (Duration) async throws -> Void,
        onKeptNetworkRoute: (@MainActor (URL, SparkIdentity) -> Void)?
    ) {
        self.runtime = runtime
        self.operations = operations
        self.networkPollAttempts = attempts
        self.poller = SparkSettingsNetworkPoller(
            runtime: runtime,
            networkRouteDiscovery: discovery,
            networkPollAttempts: attempts,
            networkPollDelay: delay,
            observe: { [weak operations] in operations?.lastOperation = $0 }
        )
        self.onKeptNetworkRoute = onKeptNetworkRoute
        resetTravelCredentials()
    }

    var directEthernetEnabled: Bool {
        optimisticDirectEthernet ?? snapshot()?.directEthernetEnabled ?? false
    }

    var travelEnabled: Bool {
        optimisticTravelEnabled ?? snapshot()?.travelAccessPoint.enabled ?? false
    }

    func connectSelectedWifi() async {
        guard let ssid = selectedWifiSSID,
            let network = wifi()?.networks.first(where: { $0.ssid == ssid })
        else { return }
        let password = network.security == .open ? nil : wifiPassword
        let request = GeneratedAPI.ConnectWifiRequest(
            ssid: ssid,
            passphrase: password,
            hidden: false
        )
        let key = UUID()
        await performNetworkChange(
            label: String(localized: "Connecting to Wi-Fi"),
            reason: String(localized: "Confirm changing this Spark’s Wi-Fi network.")
        ) { presence in
            try await self.runtime.connectWifi(
                route: self.operations.route,
                request: request,
                idempotencyKey: key,
                userPresence: presence
            )
        }
        if operations.errorMessage == nil {
            wifiPassword = ""
            self.selectedWifiSSID = nil
        }
    }

    func forgetWifi(_ ssid: String) async {
        let key = UUID()
        await operations.perform(
            label: String(localized: "Forgetting Wi-Fi"),
            reason: String(localized: .confirmForgettingNetwork(ssid))
        ) { presence in
            try await self.runtime.forgetWifi(
                route: self.operations.route,
                request: .init(ssid: ssid),
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    var canApplyManualLanIpv4: Bool {
        !lanAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !lanGateway.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !manualLanDnsServers.isEmpty
            && (1...30).contains(lanPrefixLength)
    }

    func applyManualLanIpv4() async {
        guard canApplyManualLanIpv4 else {
            operations.errorMessage = String(
                localized: "Enter an IPv4 address, prefix, gateway and at least one DNS server."
            )
            return
        }
        let address = lanAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = GeneratedAPI.ConfigureLanIpv4Request(
            address: address,
            prefixLength: lanPrefixLength,
            gateway: lanGateway.trimmingCharacters(in: .whitespacesAndNewlines),
            dnsServers: manualLanDnsServers
        )
        let key = UUID()
        var candidate = URLComponents(url: operations.route, resolvingAgainstBaseURL: false)
        candidate?.host = address
        await performNetworkChange(
            label: String(localized: "Updating LAN address"),
            reason:
                String(
                    localized:
                        "Confirm changing this Spark’s LAN address. It will restore the old address after 30 seconds unless you keep the change."
                ),
            preferredCandidateRoute: candidate?.url,
            pollAttempts: 56
        ) { presence in
            try await self.runtime.configureLanIpv4(
                route: self.operations.route,
                request: request,
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    private var manualLanDnsServers: [String] {
        lanDNSServers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func setDirectEthernet(_ enabled: Bool) async {
        let key = UUID()
        optimisticDirectEthernet = enabled
        await performNetworkChange(
            label: String(localized: "Updating direct Ethernet"),
            reason: String(localized: "Confirm changing the direct Ethernet profile on this Spark.")
        ) { presence in
            try await self.runtime.configureDirectEthernet(
                route: self.operations.route,
                enabled: enabled,
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    func setTravelAccessPoint(_ enabled: Bool) async {
        let key = UUID()
        optimisticTravelEnabled = enabled
        let request = GeneratedAPI.ConfigureTravelAccessPointRequest(
            enabled: enabled,
            ssid: enabled ? travelSSID : nil,
            passphrase: enabled ? travelPassword : nil
        )
        if enabled {
            await performNetworkChange(
                label: String(localized: "Starting travel mode"),
                reason: String(localized: "Confirm changing travel Wi-Fi on this Spark.")
            ) { presence in
                try await self.runtime.configureTravelAccessPoint(
                    route: self.operations.route,
                    request: request,
                    idempotencyKey: key,
                    userPresence: presence
                )
            }
        } else {
            await operations.perform(
                label: String(localized: "Stopping travel mode"),
                reason: String(localized: "Confirm changing travel Wi-Fi on this Spark.")
            ) { presence in
                try await self.runtime.configureTravelAccessPoint(
                    route: self.operations.route,
                    request: request,
                    idempotencyKey: key,
                    userPresence: presence
                )
            }
        }
        if operations.errorMessage == nil, !enabled {
            resetTravelCredentials()
        }
    }

    func keepNetworkChanges() async {
        guard operations.activeMutation == nil,
            let pending = pendingNetworkChange,
            pending.canKeep,
            let verifiedRoute = pending.verifiedRoute,
            let verifiedIdentity = pendingNetworkIdentity
        else { return }

        operations.activeMutation = String(localized: "Keeping network changes")
        operations.errorMessage = nil
        operations.successMessage = nil
        defer { operations.activeMutation = nil }

        do {
            // Hoisted so the presence-enrollment retry reuses the same key.
            let confirmationKey = UUID()
            var confirmation = try await operations.submitAuthorized(
                reason: String(localized: "Confirm keeping this Spark’s new network route."),
                enrollmentRoute: verifiedRoute
            ) { presence in
                try await self.runtime.confirmNetworkChange(
                    route: verifiedRoute,
                    configurationID: pending.configurationID,
                    idempotencyKey: confirmationKey,
                    userPresence: presence
                )
            }
            confirmation = try await operations.waitForCompletion(
                confirmation,
                polling: verifiedRoute
            )
            guard confirmation.state == .succeeded else {
                throw APIError(
                    .local(
                        message: String(
                            localized: "The Spark could not keep the new network route."
                        )
                    ),
                    code: confirmation.errorCode
                )
            }
            operations.route = verifiedRoute
            pendingNetworkChange = nil
            pendingNetworkIdentity = nil
            operations.successMessage = String(localized: "Network changes kept.")
            await refresh()
            onKeptNetworkRoute?(verifiedRoute, verifiedIdentity)
        } catch {
            if error is UserPresenceAuthorizationError {
                operations.errorMessage =
                    String(
                        localized:
                            "The change was not kept. The Spark will restore its previous network automatically."
                    )
            } else if let api = error as? APIError, api.code == "SETTING_STILL_APPLYING" {
                operations.errorMessage = String(
                    localized:
                        "The Spark is still confirming the new route. Refresh in a moment before deciding."
                )
            } else {
                operations.errorMessage =
                    String(
                        localized:
                            "The new route was not confirmed. The Spark will restore its previous network automatically."
                    )
            }
        }
    }

    func rollbackNetworkChanges() async {
        guard operations.activeMutation == nil, let pending = pendingNetworkChange else { return }
        let rollbackRoute = pending.verifiedRoute ?? operations.route
        operations.activeMutation = String(localized: "Restoring the previous network")
        operations.errorMessage = nil
        operations.successMessage = nil
        defer { operations.activeMutation = nil }

        do {
            let rollbackKey = UUID()
            var rollback = try await operations.submitAuthorized(
                reason: String(localized: "Confirm restoring this Spark’s previous network."),
                enrollmentRoute: rollbackRoute
            ) { presence in
                try await self.runtime.rollbackNetworkChange(
                    route: rollbackRoute,
                    configurationID: pending.configurationID,
                    idempotencyKey: rollbackKey,
                    userPresence: presence
                )
            }
            rollback = try await poller.waitForNetworkResolution(
                rollback,
                preferredRoute: rollbackRoute,
                fallbackRoute: operations.route
            )
            guard rollback.state == .succeeded else {
                throw APIError(
                    .local(
                        message: String(
                            localized: "The Spark could not restore its previous network yet."
                        )
                    ),
                    code: rollback.errorCode
                )
            }
            pendingNetworkChange = nil
            pendingNetworkIdentity = nil
            clearAllOptimisticState()
            operations.successMessage = String(localized: "Previous network restored.")
            await refresh()
        } catch {
            operations.errorMessage =
                String(
                    localized:
                        "SparkPilot could not request an immediate restore. The Spark’s own safety timer remains active."
                )
        }
    }

    private func performNetworkChange(
        label: String,
        reason: String,
        preferredCandidateRoute: URL? = nil,
        pollAttempts: Int? = nil,
        submit: @escaping (any UserPresenceProofSigning) async throws -> SparkAPI.Operation
    ) async {
        guard operations.activeMutation == nil, pendingNetworkChange == nil else {
            // Report an in-flight change so optimistic controls cannot imply that a second mutation was accepted.
            clearAllOptimisticState()
            operations.errorMessage =
                pendingNetworkChange != nil
                ? String(localized: "Keep or undo the pending network change first.")
                : String(localized: "Another change is still being applied. Wait for it to finish.")
            return
        }
        operations.activeMutation = label
        operations.errorMessage = nil
        operations.successMessage = nil
        defer { operations.activeMutation = nil }

        do {
            let originalRoute = operations.route
            let expectedIdentity = try await runtime.identity(route: originalRoute)
            let operation = try await operations.submitAuthorized(
                reason: reason,
                enrollmentRoute: originalRoute,
                submit: submit
            )
            operations.lastOperation = operation
            pendingNetworkChange = PendingSparkNetworkChange(
                configurationID: operation.id,
                label: label,
                phase: .findingNewRoute,
                verifiedRoute: nil
            )
            pendingNetworkIdentity = nil

            let handoff = try await poller.waitForNetworkHandoff(
                operation,
                originalRoute: originalRoute,
                expectedNodeID: expectedIdentity.nodeID,
                preferredCandidateRoute: preferredCandidateRoute,
                maxAttempts: pollAttempts ?? networkPollAttempts
            )
            operations.lastOperation = handoff.operation
            pendingNetworkChange = PendingSparkNetworkChange(
                configurationID: operation.id,
                label: label,
                phase: .readyToKeep,
                verifiedRoute: handoff.route
            )
            pendingNetworkIdentity = handoff.identity
            operations.errorMessage = nil
        } catch {
            clearAllOptimisticState()
            if let operation = operations.lastOperation,
                operation.id == pendingNetworkChange?.configurationID,
                operation.state == .failed || operation.state == .cancelled
            {
                pendingNetworkChange = nil
                pendingNetworkIdentity = nil
            }
            if error is CancellationError {
                operations.errorMessage =
                    String(
                        localized:
                            "Setup stopped without keeping the change. The Spark will restore its previous network automatically."
                    )
            } else if error is UserPresenceAuthorizationError {
                operations.errorMessage =
                    String(
                        localized:
                            "Nothing changed because this Apple device could not confirm you are present."
                    )
            } else if let api = error as? APIError,
                api.code == "NETWORK_AUTHENTICATION_FAILED"
                    || api.code == "INVALID_WIFI_CREDENTIALS"
            {
                operations.errorMessage = String(
                    localized: "That Wi-Fi password is wrong. Check it and try again."
                )
            } else if let api = error as? APIError,
                api.code == "NETWORK_ADDRESS_IN_USE"
            {
                operations.errorMessage = String(
                    localized: "Another device is already using that IPv4 address."
                )
            } else if let api = error as? APIError,
                api.code == "INVALID_STATIC_IPV4"
            {
                operations.errorMessage = String(
                    localized: "Check the IPv4 address, prefix, gateway and DNS values."
                )
            } else if let handoff = error as? NetworkHandoffError,
                handoff == .identityMismatch
            {
                operations.errorMessage =
                    String(
                        localized:
                            "A different Spark answered on the new route. Nothing was confirmed, and this Spark will restore its previous network automatically."
                    )
            } else {
                operations.errorMessage =
                    String(
                        localized:
                            "SparkPilot could not verify the new route in time. Nothing was confirmed, and the Spark will restore its previous network automatically."
                    )
            }
        }
    }

    private func resetTravelCredentials() {
        travelSSID = "Spark-" + UUID().uuidString.prefix(4).uppercased()
        travelPassword = String(
            UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
        )
    }
}
