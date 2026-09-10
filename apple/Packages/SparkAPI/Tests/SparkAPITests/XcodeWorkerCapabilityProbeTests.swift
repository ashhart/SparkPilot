import Foundation
import Testing

@testable import SparkAPI

#if os(macOS)
    /// PLAN 43.3: the worker advertises the simulators simctl can boot, named with their runtime.
    @Test func theSimulatorListingBecomesNamedDevices() {
        let json = """
            {
              "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                  { "name": "iPhone 17", "udid": "A", "isAvailable": true },
                  { "name": "iPhone 17 Pro", "udid": "B", "isAvailable": true },
                  { "name": "iPhone 15", "udid": "C", "isAvailable": false }
                ],
                "com.apple.CoreSimulator.SimRuntime.watchOS-26-0": [
                  { "name": "Apple Watch Series 11 (46mm)", "udid": "D", "isAvailable": true }
                ]
              }
            }
            """
        let names = XcodeWorkerCapabilityProbe.simulatorNames(from: Data(json.utf8))
        #expect(
            names == [
                "Apple Watch Series 11 (46mm) (watchOS 26.0)", "iPhone 17 (iOS 26.5)",
                "iPhone 17 Pro (iOS 26.5)",
            ]
        )
    }

    @Test func anUnreadableListingAdvertisesNoSimulators() {
        #expect(XcodeWorkerCapabilityProbe.simulatorNames(from: Data("nonsense".utf8)) == [])
    }

    @Test func theListingIsCappedAtTheContractsLimit() {
        let devices = (0..<200).map { "{\"name\": \"Device \($0)\", \"isAvailable\": true}" }
        let json =
            "{\"devices\": {\"com.apple.CoreSimulator.SimRuntime.iOS-26-5\": [\(devices.joined(separator: ","))]}}"
        #expect(XcodeWorkerCapabilityProbe.simulatorNames(from: Data(json.utf8)).count == 128)
    }
#endif
