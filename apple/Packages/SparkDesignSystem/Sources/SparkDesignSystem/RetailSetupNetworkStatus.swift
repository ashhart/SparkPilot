import Foundation
import SparkCore

/// QA-02: what the setup Wi-Fi fields are entitled to say about the network name and the password.
struct RetailSetupNetworkStatus: Equatable, Sendable {
    /// The shortest passphrase WPA accepts, which is also what Join Spark waits for.
    static let minimumPassphraseBytes = 8

    enum Network: Equatable, Sendable {
        case empty
        /// A name manual setup cannot turn into a Spark address.
        case unusableName
        /// A usable name that this device has not observed; joining is the first thing that will look.
        case notSeenYet
        /// This device is associated with exactly this setup network.
        case found
    }

    enum Password: Equatable, Sendable {
        case empty
        case tooShort
        case ok
    }

    let network: Network
    let password: Password

    static func resolve(
        ssid: String,
        detectedSSID: String?,
        passphrase: String
    ) -> RetailSetupNetworkStatus {
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        let network: Network
        if trimmed.isEmpty {
            network = .empty
        } else if SparkSetupAddress.hostname(for: ssid) == nil {
            network = .unusableName
        } else if let detectedSSID,
            detectedSSID.compare(trimmed, options: .caseInsensitive) == .orderedSame
        {
            network = .found
        } else {
            network = .notSeenYet
        }

        let bytes = passphrase.lengthOfBytes(using: .utf8)
        let password: Password =
            bytes == 0 ? .empty : (bytes < minimumPassphraseBytes ? .tooShort : .ok)
        return RetailSetupNetworkStatus(network: network, password: password)
    }

    /// Only a network this device is actually on earns the green confirmation.
    var showsFoundConfirmation: Bool { network == .found }

    /// A usable name that has not been seen gets a neutral note instead of a claim.
    var showsNotSeenNote: Bool { network == .notSeenYet }

    var isComplete: Bool {
        (network == .found || network == .notSeenYet) && password == .ok
    }

    /// The rule Join Spark waits for, stated under the field rather than left to be guessed.
    var passwordRule: String {
        String(
            localized:
                "The Wi-Fi password printed on the Quick Start card is at least 8 characters. Join Spark stays off until the whole password is typed."
        )
    }

    /// Whether the rule should read as a correction rather than as help.
    var passwordRuleIsUnmet: Bool { password == .tooShort }
}
