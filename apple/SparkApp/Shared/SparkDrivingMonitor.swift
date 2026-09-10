#if canImport(CarPlay)
    import CarPlay
    import CoreLocation
    import Foundation

    /// Listens to the car for the one fact the keyboard gate needs: is the car moving.
    @MainActor
    final class SparkDrivingMonitor: NSObject, CLLocationManagerDelegate,
        CPSessionConfigurationDelegate
    {
        private let bridge: SparkCarPlayBridge
        private let location = CLLocationManager()
        private var configuration: CPSessionConfiguration?
        private var keyboardRestricted = false

        init(bridge: SparkCarPlayBridge) {
            self.bridge = bridge
            super.init()
            location.delegate = self
            location.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            location.distanceFilter = 5
            location.activityType = .automotiveNavigation
        }

        /// Start on connect: the car's own restriction first, speed as a fallback for cars without one.
        func start() {
            let configuration = CPSessionConfiguration(delegate: self)
            self.configuration = configuration
            keyboardRestricted = configuration.limitedUserInterfaces.contains(.keyboard)
            report(speed: nil)
            if location.authorizationStatus == .notDetermined {
                location.requestWhenInUseAuthorization()
            }
            location.startUpdatingLocation()
        }

        /// Stop on disconnect so the phone never keeps a location fix for a car that is gone.
        func stop() {
            location.stopUpdatingLocation()
            configuration = nil
            keyboardRestricted = false
        }

        private func report(speed: Double?) {
            bridge.observe(
                SparkDrivingSignals(
                    carPlayConnected: bridge.isConnected,
                    keyboardRestrictedByCar: keyboardRestricted,
                    speedMetersPerSecond: speed,
                    observedAt: Date()
                )
            )
        }

        nonisolated func sessionConfiguration(
            _ sessionConfiguration: CPSessionConfiguration,
            limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
        ) {
            let restricted = limitedUserInterfaces.contains(.keyboard)
            Task { @MainActor in
                self.keyboardRestricted = restricted
                self.report(speed: nil)
            }
        }

        nonisolated func locationManager(
            _ manager: CLLocationManager,
            didUpdateLocations locations: [CLLocation]
        ) {
            guard let latest = locations.last, latest.speed >= 0,
                abs(latest.timestamp.timeIntervalSinceNow)
                    <= SparkDrivingStateReducer.speedFreshness
            else { return }
            let speed = latest.speed
            Task { @MainActor in self.report(speed: speed) }
        }

        nonisolated func locationManager(
            _ manager: CLLocationManager,
            didFailWithError error: any Error
        ) {
            Task { @MainActor in self.report(speed: nil) }
        }
    }
#endif
