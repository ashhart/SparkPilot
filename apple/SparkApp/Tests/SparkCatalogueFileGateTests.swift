import Foundation
import Testing

@testable import SparkAppComposition

/// Verifies catalogue file suitability without treating local checks as a substitute for runtime signature verification.

@Test func aPlausibleCatalogueFileIsAccepted() {
    #expect(SparkCatalogueFileGate.inspect(isRegularFile: true, fileSizeBytes: 4_096) == nil)
}

/// Accept both inclusive catalogue-file size boundaries.
@Test func theSizeLimitsAreInclusiveAtBothEnds() {
    #expect(SparkCatalogueFileGate.inspect(isRegularFile: true, fileSizeBytes: 2) == nil)
    #expect(
        SparkCatalogueFileGate.inspect(isRegularFile: true, fileSizeBytes: 2 * 1024 * 1024) == nil
    )

    #expect(
        SparkCatalogueFileGate.inspect(isRegularFile: true, fileSizeBytes: 1) == .unusableFile
    )
    #expect(
        SparkCatalogueFileGate.inspect(isRegularFile: true, fileSizeBytes: 2 * 1024 * 1024 + 1)
            == .unusableFile
    )
}

/// Reject empty files locally before they can produce a misleading catalogue signature error.
@Test func anEmptyFileIsRefusedBeforeItIsRead() {
    #expect(
        SparkCatalogueFileGate.inspect(isRegularFile: true, fileSizeBytes: 0) == .unusableFile
    )
}

/// Reject directories and unknown file metadata rather than assuming either is a regular file.
@Test func onlyARegularFileIsAccepted() {
    #expect(
        SparkCatalogueFileGate.inspect(isRegularFile: false, fileSizeBytes: 4_096)
            == .unusableFile
    )
    #expect(
        SparkCatalogueFileGate.inspect(isRegularFile: nil, fileSizeBytes: 4_096) == .unusableFile
    )
    #expect(
        SparkCatalogueFileGate.inspect(isRegularFile: true, fileSizeBytes: nil) == .unusableFile
    )
}

@Test func utf8TextIsHandedOnUnchanged() throws {
    let json = #"{"recipes":[],"signature":{"key_id":"catalogue-test"}}"#
    let decoded = try SparkCatalogueFileGate.decode(Data(json.utf8)).get()
    #expect(decoded == json)
}

/// Reject UTF-16 catalogue bytes after plausible file metadata passes.
@Test func textThatIsNotUTF8IsRefusedWithItsOwnExplanation() {
    let utf16 = Data("{}".data(using: .utf16)!)
    #expect(SparkCatalogueFileGate.decode(utf16) == .failure(.notUTF8))
    #expect(
        SparkCatalogueFileGate.Rejection.notUTF8.message
            == "Choose a UTF-8 signed catalogue JSON file up to 2 MB."
    )
}

/// Provide actionable copy for every file-picker refusal.
@Test func everyRefusalExplainsItself() {
    let rejections: [SparkCatalogueFileGate.Rejection] = [
        .unusableFile, .notUTF8, .unreadable, .unopenable,
    ]
    for rejection in rejections {
        #expect(!rejection.message.isEmpty)
    }
    #expect(
        SparkCatalogueFileGate.Rejection.unusableFile.message
            == "Choose a regular UTF-8 catalogue JSON file up to 2 MB."
    )
}
