import Foundation
import Network
import Observation

/// Deliver Bonjour hints on the main actor while pinned API identity verification remains authoritative (§12.3).
@MainActor
@Observable
public final class SparkDiscoveryService {
    public private(set) var nodes: [DiscoveredSpark] = []
    public private(set) var permissionState: LocalNetworkPermissionState = .notDetermined
    public private(set) var lastError: Error?

    private var browser: NWBrowser?
    private var merger = DiscoveryMerger()
    private let advertisementFactory: DiscoveryAdvertisementFactory
    /// Advertisements older than this are dropped unless refreshed.
    public var staleInterval: TimeInterval = 30

    public init() {
        advertisementFactory = DiscoveryAdvertisementFactory(now: Date.init)
    }

    public init(now: @escaping @Sendable () -> Date) {
        advertisementFactory = DiscoveryAdvertisementFactory(now: now)
    }

    public func start() {
        guard browser == nil else { return }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_spark-runtime._tcp", domain: "local."),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                Task { @MainActor in
                    if isLocalNetworkDenied(error) {
                        self.permissionState = .denied
                    } else {
                        self.lastError = error
                    }
                }
            case .waiting(let error):
                Task { @MainActor in
                    if isLocalNetworkDenied(error) {
                        self.permissionState = .denied
                    }
                }
            default:
                Task { @MainActor in
                    if self.permissionState == .notDetermined {
                        self.permissionState = .granted
                    }
                }
            }
        }

        let advertisementFactory = self.advertisementFactory
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let mapped = results.compactMap { result -> NodeAdvertisement? in
                guard case .service(let name, _, _, let interface) = result.endpoint else {
                    return nil
                }
                return advertisementFactory.makeAdvertisement(
                    instance: name,
                    endpoint: result.endpoint,
                    interfaceKind: SparkInterfaceKind(interface: interface),
                    txt: NodeTXT(metadata: result.metadata)
                )
            }
            Task { @MainActor in
                guard let self else { return }
                self.processAdvertisements(mapped)
            }
        }

        self.browser = browser
        browser.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        merger = DiscoveryMerger()
        nodes = []
    }

    func makeAdvertisement(
        instance: String,
        endpoint: NWEndpoint,
        interfaceKind: SparkInterfaceKind,
        txt: NodeTXT
    ) -> NodeAdvertisement {
        advertisementFactory.makeAdvertisement(
            instance: instance,
            endpoint: endpoint,
            interfaceKind: interfaceKind,
            txt: txt
        )
    }

    func processAdvertisements(_ advertisements: [NodeAdvertisement]) {
        // Preserve short-node-ID merge keys for unchanged advertisements.
        for advertisement in advertisements {
            _ = merger.upsert(advertisement)
        }
        merger.removeStale(
            olderThan: staleInterval,
            now: advertisementFactory.now()
        )
        nodes = merger.all.map(makeDiscovered)
            .sorted { $0.displayName < $1.displayName }
    }

    private func makeDiscovered(_ advertisement: NodeAdvertisement) -> DiscoveredSpark {
        let id =
            advertisement.mergeKey.hasPrefix("instance:")
            ? "\(advertisement.endpoint)" : advertisement.mergeKey
        let interface: NWInterface? = {
            if case .service(_, _, _, let iface) = advertisement.endpoint {
                return iface
            }
            return nil
        }()
        return DiscoveredSpark(
            id: id,
            displayName: advertisement.instance,
            endpoint: advertisement.endpoint,
            interface: interface,
            shortNodeID: advertisement.shortNodeID,
            clusterID: advertisement.clusterID
        )
    }
}

private struct DiscoveryAdvertisementFactory: Sendable {
    let now: @Sendable () -> Date

    func makeAdvertisement(
        instance: String,
        endpoint: NWEndpoint,
        interfaceKind: SparkInterfaceKind,
        txt: NodeTXT
    ) -> NodeAdvertisement {
        NodeAdvertisement(
            instance: instance,
            endpoint: endpoint,
            interfaceKind: interfaceKind,
            txt: txt,
            discoveredAt: now()
        )
    }
}

private func isLocalNetworkDenied(_ error: NWError) -> Bool {
    switch error {
    case .posix(let err):
        return err == .EPERM
    case .dns:
        return false
    default:
        return false
    }
}
