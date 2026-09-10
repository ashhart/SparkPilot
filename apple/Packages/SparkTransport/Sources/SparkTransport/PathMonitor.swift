import Foundation
import Network

/// Observe interface changes on a serial callback queue to trigger route evaluation (§13.5).
final class InterfaceMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "spark.path-monitor")

    var onPath: (@Sendable (NWPath) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.onPath?(path)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

/// Summarises the current default path for the route label.
public struct CurrentInterface: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case wired
        case wifi
        case cellular
        case other
    }

    public let kind: Kind
    public let isConstrained: Bool
    public let isExpensive: Bool

    public init(path: NWPath) {
        if path.usesInterfaceType(.wiredEthernet) {
            self.kind = .wired
        } else if path.usesInterfaceType(.wifi) {
            self.kind = .wifi
        } else if path.usesInterfaceType(.cellular) {
            self.kind = .cellular
        } else {
            self.kind = .other
        }
        self.isConstrained = path.isConstrained
        self.isExpensive = path.isExpensive
    }
}
