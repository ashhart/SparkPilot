import Foundation
import Network
import Observation

public struct BootstrapSpark: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let endpoint: NWEndpoint

    public init(displayName: String, endpoint: NWEndpoint) {
        self.id = "\(endpoint)"
        self.displayName = displayName
        self.endpoint = endpoint
    }
}

/// Browse SSH reachability for uninstalled DGX OS without exposing shell execution to the UI.
@MainActor
@Observable
public final class BootstrapDiscoveryService {
    public private(set) var candidates: [BootstrapSpark] = []
    public private(set) var lastError: Error?

    private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_ssh._tcp", domain: "local."),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            Task { @MainActor in
                self?.lastError = error
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let candidates = results.compactMap { result -> BootstrapSpark? in
                guard case .service(let name, _, _, _) = result.endpoint else {
                    return nil
                }
                return BootstrapSpark(displayName: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                self?.candidates = candidates.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
            }
        }

        self.browser = browser
        browser.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        candidates = []
    }

    public func candidate(matching machineName: String) -> BootstrapSpark? {
        let expected =
            machineName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".local", with: "", options: [.caseInsensitive, .anchored])

        return candidates.first {
            $0.displayName.compare(expected, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }
    }
}

public enum NetworkHandoffState: Sendable, Equatable {
    case checking
    case wifiAvailable
    case otherNetworkAvailable
    case offline
}

/// Observe setup-hotspot handoff without reading or retaining the owner's home SSID.
@MainActor
@Observable
public final class NetworkHandoffMonitor {
    public private(set) var state: NetworkHandoffState = .checking

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "spark.onboarding-network-handoff")
    private var started = false

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let state: NetworkHandoffState
            if path.status != .satisfied {
                state = .offline
            } else if path.usesInterfaceType(.wifi) {
                state = .wifiAvailable
            } else {
                state = .otherNetworkAvailable
            }
            Task { @MainActor in
                self?.state = state
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        guard started else { return }
        monitor.cancel()
        started = false
        state = .checking
    }

    deinit {
        monitor.cancel()
    }
}
