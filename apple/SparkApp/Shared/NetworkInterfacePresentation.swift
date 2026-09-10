import Foundation

/// Maps free-form runtime network states to accessible labels while preserving reported addresses and names as data.
enum NetworkInterfacePresentation {
    static func typeLabel(_ type: String) -> String {
        switch type {
        case "ethernet": String(localized: "Ethernet")
        case "wifi": String(localized: "Wi-Fi")
        case "bridge": String(localized: "Bridge")
        case "loopback": String(localized: "Loopback")
        // Use a generic interface label for unknown runtime kinds.
        default: String(localized: "Interface")
        }
    }

    static func stateLabel(_ state: String) -> String {
        switch state {
        case "connected": String(localized: "Connected")
        case "disconnected": String(localized: "Disconnected")
        case "unavailable": String(localized: "Unavailable")
        default: String(localized: "Unknown")
        }
    }

    /// Distinguishes interface, route, gateway and DNS failures because each requires a different recovery.
    static func internetLabel(
        state: String,
        reachable: Bool,
        gatewayReachable: Bool?,
        dnsReachable: Bool?
    ) -> String {
        if state != "connected" { return String(localized: "Not connected") }
        if reachable { return String(localized: "Reachable") }
        if gatewayReachable == false { return String(localized: "Gateway unreachable") }
        if dnsReachable == false { return String(localized: "DNS unavailable") }
        return String(localized: "Not reachable")
    }

    /// Format link speed in the user's locale, switching from megabits to gigabits above one thousand.
    static func linkSpeed(_ megabits: Int64) -> String {
        if megabits >= 1_000 {
            let gigabits = Double(megabits) / 1_000
            let fractionLength = gigabits == gigabits.rounded() ? 0 : 1
            return String(
                localized: .linkSpeedGigabits(
                    gigabits.formatted(.number.precision(.fractionLength(fractionLength)))
                )
            )
        }
        return String(localized: .linkSpeedMegabits(megabits.formatted()))
    }

    /// Displays the network name as data and formats signal strength as a localised percentage.
    static func wifiValue(name: String, signalPercent: Int?) -> String {
        guard let signalPercent else { return name }
        return String(
            localized: .networkNameAndSignal(
                name: name,
                signal: (Double(signalPercent) / 100).formatted(.percent)
            )
        )
    }
}
