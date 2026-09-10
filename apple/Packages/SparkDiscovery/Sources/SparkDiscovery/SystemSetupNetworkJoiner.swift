import Foundation

#if os(iOS)
    import CoreLocation
    import NetworkExtension
#elseif os(macOS)
    import CoreLocation
    @preconcurrency import CoreWLAN
#endif

/// Confine production Wi-Fi changes to this boundary and the iOS confirmation flow.
@MainActor
public final class SystemSetupNetworkJoiner: SetupNetworkJoining {
    public init() {}

    public var canJoinSetupNetwork: Bool {
        #if os(iOS) || os(macOS)
            return true
        #else
            return false
        #endif
    }

    @discardableResult
    public func join(_ credentials: SetupNetworkCredentials) async throws -> String {
        #if os(iOS)
            let configuration: NEHotspotConfiguration
            switch credentials.match {
            case .exactSSID(let ssid):
                configuration = NEHotspotConfiguration(
                    ssid: ssid,
                    passphrase: credentials.passphrase,
                    isWEP: false
                )
            case .ssidPrefix(let prefix):
                // Delegate network scanning and selection to iOS without exposing the nearby network list to the app.
                configuration = NEHotspotConfiguration(
                    ssidPrefix: prefix,
                    passphrase: credentials.passphrase,
                    isWEP: false
                )
            }
            configuration.joinOnce = true

            // Record the pre-existing network so a coincidental prefix match cannot prove successful setup association.
            let previousSSID = await NEHotspotNetwork.fetchCurrent()?.ssid

            let alreadyAssociated: Bool = try await withCheckedThrowingContinuation {
                continuation in
                NEHotspotConfigurationManager.shared.apply(configuration) { error in
                    guard let error else {
                        continuation.resume(returning: false)
                        return
                    }
                    let nsError = error as NSError
                    if nsError.domain == NEHotspotConfigurationErrorDomain,
                        nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
                    {
                        continuation.resume(returning: true)
                        return
                    }
                    continuation.resume(throwing: Self.map(error: nsError))
                }
            }
            return try await waitUntilAssociated(
                matching: credentials.match,
                ignoring: alreadyAssociated ? nil : previousSSID
            )
        #elseif os(macOS)
            return try await Task.detached(priority: .userInitiated) {
                guard let interface = CWWiFiClient.shared().interface() else {
                    throw SetupNetworkJoinError.unsupportedPlatform
                }

                let networks: Set<CWNetwork>
                do {
                    switch credentials.match {
                    case .exactSSID(let ssid):
                        networks = try interface.scanForNetworks(withName: ssid)
                    case .ssidPrefix:
                        networks = try interface.scanForNetworks(withName: nil)
                    }
                } catch let error as NSError {
                    throw Self.mapMac(error: error)
                }

                let matches = networks.filter { network in
                    guard let ssid = network.ssid else { return false }
                    return credentials.match.matches(ssid)
                }
                .sorted { $0.rssiValue > $1.rssiValue }

                guard let network = matches.first, let ssid = network.ssid else {
                    throw SetupNetworkJoinError.connectionTimedOut
                }
                if case .ssidPrefix = credentials.match, matches.count > 1 {
                    throw SetupNetworkJoinError.invalidSSIDPrefix
                }

                do {
                    try interface.associate(to: network, password: credentials.passphrase)
                } catch let error as NSError {
                    throw Self.mapMac(error: error)
                }
                guard credentials.match.matches(interface.ssid() ?? ssid) else {
                    throw SetupNetworkJoinError.connectionTimedOut
                }
                return interface.ssid() ?? ssid
            }.value
        #else
            throw SetupNetworkJoinError.unsupportedPlatform
        #endif
    }

    public func forget(ssid: String) {
        #if os(iOS)
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        #elseif os(macOS)
            Task.detached(priority: .userInitiated) {
                guard let interface = CWWiFiClient.shared().interface(),
                    interface.ssid()?.caseInsensitiveCompare(ssid) == .orderedSame
                else { return }
                interface.disassociate()
            }
        #endif
    }

    #if os(macOS)
        private nonisolated static func mapMac(error: NSError) -> SetupNetworkJoinError {
            switch error.code {
            case CWErr.cwInvalidParameterErr.rawValue:
                return .invalidConfiguration
            case CWErr.cwOperationNotPermittedErr.rawValue:
                return .systemDenied
            case CWErr.cwAssociationDeniedErr.rawValue:
                return .userDenied
            case CWErr.cwTimeoutErr.rawValue, CWErr.cwSupplicantTimeoutErr.rawValue:
                return .connectionTimedOut
            default:
                return .failed(code: error.code)
            }
        }
    #endif

    #if os(iOS)
        /// Wait for a matching observed SSID while excluding the network already joined before the request.
        private func waitUntilAssociated(
            matching match: SetupNetworkMatch,
            ignoring previousSSID: String?
        ) async throws -> String {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(12))

            while clock.now < deadline {
                if let network = await NEHotspotNetwork.fetchCurrent(),
                    match.matches(network.ssid),
                    previousSSID?.caseInsensitiveCompare(network.ssid) != .orderedSame
                {
                    return network.ssid
                }
                try await Task.sleep(for: .milliseconds(350))
            }

            throw SetupNetworkJoinError.connectionTimedOut
        }

        /// Handle configuration callbacks nonisolated because they arrive outside the main actor.
        private nonisolated static func map(error: NSError) -> SetupNetworkJoinError {
            guard error.domain == NEHotspotConfigurationErrorDomain else {
                return .failed(code: error.code)
            }
            switch error.code {
            case NEHotspotConfigurationError.invalidSSIDPrefix.rawValue:
                return .invalidSSIDPrefix
            case NEHotspotConfigurationError.invalid.rawValue,
                NEHotspotConfigurationError.invalidSSID.rawValue,
                NEHotspotConfigurationError.invalidWPAPassphrase.rawValue:
                return .invalidConfiguration
            case NEHotspotConfigurationError.userDenied.rawValue:
                return .userDenied
            case NEHotspotConfigurationError.systemDenied.rawValue,
                NEHotspotConfigurationError.userUnauthorized.rawValue:
                return .systemDenied
            case NEHotspotConfigurationError.pending.rawValue:
                return .requestPending
            case NEHotspotConfigurationError.applicationIsNotInForeground.rawValue:
                return .applicationNotForeground
            default:
                return .failed(code: error.code)
            }
        }
    #endif
}
