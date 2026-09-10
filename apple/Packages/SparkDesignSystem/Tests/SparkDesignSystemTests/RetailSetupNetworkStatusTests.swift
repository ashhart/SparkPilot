import Foundation
import Testing

@testable import SparkDesignSystem

/// QA-02: "Ready to join Spark-QA-TEST" appeared in green with a filled checkmark from the typed characters alone.
@Test func aTypedNetworkNameIsNotTreatedAsANetworkThatWasFound() {
    let typed = RetailSetupNetworkStatus.resolve(
        ssid: "Spark-QA-TEST",
        detectedSSID: nil,
        passphrase: ""
    )

    #expect(typed.network == .notSeenYet)
    #expect(!typed.showsFoundConfirmation)
}

/// QA-02: the confirmation is earned when this device is actually associated with that setup network.
@Test func theNetworkThisDeviceIsOnKeepsItsConfirmation() {
    let found = RetailSetupNetworkStatus.resolve(
        ssid: "spark-a1b2",
        detectedSSID: "Spark-A1B2",
        passphrase: "quickstart"
    )

    #expect(found.network == .found)
    #expect(found.showsFoundConfirmation)
    #expect(found.isComplete)
}

/// QA-02: an unusable name and an empty field are neither found nor merely unseen.
@Test func anEmptyOrUnusableNetworkNameSaysSoInstead() {
    #expect(
        RetailSetupNetworkStatus.resolve(ssid: "  ", detectedSSID: nil, passphrase: "").network
            == .empty
    )
    #expect(
        RetailSetupNetworkStatus.resolve(ssid: "!!!", detectedSSID: nil, passphrase: "").network
            == .unusableName
    )
}

/// QA-02: Join Spark stayed disabled for a password shorter than the WPA minimum and nothing on screen said so.
@Test func aPasswordShorterThanTheMinimumIsNamedRatherThanJustRefused() {
    let short = RetailSetupNetworkStatus.resolve(
        ssid: "spark-a1b2",
        detectedSSID: nil,
        passphrase: "short"
    )

    #expect(RetailSetupNetworkStatus.minimumPassphraseBytes == 8)
    #expect(short.password == .tooShort)
    #expect(!short.isComplete)
    #expect(!short.passwordRule.isEmpty)

    let empty = RetailSetupNetworkStatus.resolve(
        ssid: "spark-a1b2",
        detectedSSID: nil,
        passphrase: ""
    )
    #expect(empty.password == .empty)
    #expect(!empty.isComplete)

    let long = RetailSetupNetworkStatus.resolve(
        ssid: "spark-a1b2",
        detectedSSID: nil,
        passphrase: "12345678"
    )
    #expect(long.password == .ok)
    #expect(long.isComplete, "a network that has not been seen can still be joined")
}
