import Foundation

/// QA-01: what the Quick Start sheet can honestly show, given what the device says about its camera.
enum QuickStartScannerAvailability: Equatable, Sendable {
    /// A camera is present, permitted and scanning.
    case scanning
    /// This device has no data scanner at all — no camera, or hardware that cannot do it.
    case unsupportedDevice
    /// Scanning is supported but the camera will not answer: denied, restricted, or in use.
    case cameraUnavailable
    /// The scanner refused to start, carrying the reason it gave.
    case startFailed(String)

    static func resolve(
        isSupported: Bool,
        isAvailable: Bool,
        startError: String?
    ) -> QuickStartScannerAvailability {
        if let startError { return .startFailed(startError) }
        if !isSupported { return .unsupportedDevice }
        if !isAvailable { return .cameraUnavailable }
        return .scanning
    }

    var showsCamera: Bool { self == .scanning }

    /// The reason the scanner gave, when it gave one; nil for a device that simply cannot scan.
    var detail: String? {
        if case .startFailed(let message) = self { return message }
        return nil
    }

    var explanation: String {
        switch self {
        case .scanning:
            ""
        case .unsupportedDevice:
            String(
                localized:
                    "This device cannot scan a Quick Start code. Type the Wi-Fi name and password printed on the Quick Start card instead."
            )
        case .cameraUnavailable:
            String(
                localized:
                    "The camera is not available. Check that SparkPilot is allowed to use it in Settings, or type the Wi-Fi name and password from the Quick Start card."
            )
        case .startFailed:
            String(
                localized:
                    "The camera did not start, so there is nothing to scan with. Type the Wi-Fi name and password from the Quick Start card instead."
            )
        }
    }
}
