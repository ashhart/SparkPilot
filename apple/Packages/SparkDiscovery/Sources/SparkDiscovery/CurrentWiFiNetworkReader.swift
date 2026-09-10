import Foundation

/// One authorisation wait shared by every caller, so a second read cannot orphan the first.
@MainActor
final class WiFiAuthorizationGate {
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    var waitingCount: Int { waiters.count }

    /// Join the wait already running, or start one; the system is asked only for the first caller.
    func wait(request: @MainActor () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let isFirst = waiters.isEmpty
            waiters.append(continuation)
            if isFirst { request() }
        }
    }

    /// Answer everyone waiting at once; an answer with nobody waiting is simply dropped.
    func resolve(_ value: Bool) {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: value) }
    }
}

#if os(iOS)
    import CoreLocation
    import NetworkExtension
#elseif os(macOS)
    import CoreLocation
    @preconcurrency import CoreWLAN
#endif

#if os(iOS)
    /// Request iOS permission to read the SSID without collecting location samples.
    @MainActor
    public final class SystemCurrentWiFiNetworkReader: NSObject, CurrentWiFiNetworkReading,
        @preconcurrency CLLocationManagerDelegate
    {
        private let locationManager = CLLocationManager()
        private let authorization = WiFiAuthorizationGate()

        public override init() {
            super.init()
            locationManager.delegate = self
        }

        public func currentSSID() async -> String? {
            await currentSSID(requestingPermission: true)
        }

        public func currentSSID(requestingPermission: Bool) async -> String? {
            if let network = await NEHotspotNetwork.fetchCurrent() {
                return network.ssid
            }
            guard requestingPermission else { return nil }
            guard await ensureWiFiIdentificationPermission() else { return nil }
            return await NEHotspotNetwork.fetchCurrent()?.ssid
        }

        public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            guard manager.authorizationStatus != .notDetermined else { return }
            authorization.resolve(Self.isAuthorized(manager.authorizationStatus))
        }

        private func ensureWiFiIdentificationPermission() async -> Bool {
            let status = locationManager.authorizationStatus
            if status != .notDetermined {
                return Self.isAuthorized(status)
            }

            return await authorization.wait { [locationManager] in
                locationManager.requestWhenInUseAuthorization()
            }
        }

        private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
            status == .authorizedAlways || status == .authorizedWhenInUse
        }
    }
#elseif os(macOS)
    @MainActor
    public final class SystemCurrentWiFiNetworkReader: NSObject, CurrentWiFiNetworkReading,
        @preconcurrency CLLocationManagerDelegate
    {
        private let locationManager = CLLocationManager()
        private let authorization = WiFiAuthorizationGate()

        public override init() {
            super.init()
            locationManager.delegate = self
        }

        public func currentSSID() async -> String? {
            await currentSSID(requestingPermission: true)
        }

        public func currentSSID(requestingPermission: Bool) async -> String? {
            if !requestingPermission, locationManager.authorizationStatus == .notDetermined {
                return nil
            }
            guard await ensureWiFiIdentificationPermission() else { return nil }
            return await Task.detached(priority: .userInitiated) {
                CWWiFiClient.shared().interface()?.ssid()
            }.value
        }

        public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            guard manager.authorizationStatus != .notDetermined else { return }
            authorization.resolve(Self.isAuthorized(manager.authorizationStatus))
        }

        private func ensureWiFiIdentificationPermission() async -> Bool {
            let status = locationManager.authorizationStatus
            if status != .notDetermined { return Self.isAuthorized(status) }
            return await authorization.wait { [locationManager] in
                locationManager.requestWhenInUseAuthorization()
            }
        }

        private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
            status == .authorizedAlways
        }
    }
#else
    @MainActor
    public final class SystemCurrentWiFiNetworkReader: CurrentWiFiNetworkReading {
        public init() {}
        public func currentSSID() async -> String? { nil }
    }
#endif
