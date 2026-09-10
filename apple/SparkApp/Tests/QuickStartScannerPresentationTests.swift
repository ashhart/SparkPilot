import Foundation
import Testing

@testable import SparkAppComposition

/// QA-01: the sheet was drawn as a camera preview whatever the device answered, which is a blank rectangle when no camera does.
@Test func theQuickStartSheetOnlyShowsACameraWhenOneCanAnswer() {
    #expect(
        QuickStartScannerAvailability.resolve(
            isSupported: true,
            isAvailable: true,
            startError: nil
        ) == .scanning
    )
    #expect(
        QuickStartScannerAvailability.resolve(
            isSupported: false,
            isAvailable: false,
            startError: nil
        ) == .unsupportedDevice
    )
    #expect(
        QuickStartScannerAvailability.resolve(
            isSupported: true,
            isAvailable: false,
            startError: nil
        ) == .cameraUnavailable
    )
}

/// QA-01: `try? scanner.startScanning()` threw the reason away; a failure to start is now what the sheet shows.
@Test func aScannerThatWillNotStartExplainsItselfRatherThanShowingNothing() {
    let failed = QuickStartScannerAvailability.resolve(
        isSupported: true,
        isAvailable: true,
        startError: "The camera is in use by another app."
    )

    #expect(failed == .startFailed("The camera is in use by another app."))
    #expect(!failed.showsCamera)
    #expect(failed.detail == "The camera is in use by another app.")
}

/// QA-01: every state that is not a live camera has to say so in plain words and offer the way on.
@Test func everyUnscannableStateExplainsItselfAndOffersManualEntry() {
    let states: [QuickStartScannerAvailability] = [
        .unsupportedDevice, .cameraUnavailable, .startFailed("no camera"),
    ]

    for state in states {
        #expect(!state.showsCamera)
        #expect(!state.explanation.isEmpty)
    }
    #expect(QuickStartScannerAvailability.scanning.showsCamera)

    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let sheet = try! String(
        contentsOf: appRoot.appending(path: "Shared/QuickStartScannerSheet.swift"),
        encoding: .utf8
    )
    #expect(sheet.contains("Enter details manually"))
    #expect(!sheet.contains("try? scanner.startScanning()"))
}
