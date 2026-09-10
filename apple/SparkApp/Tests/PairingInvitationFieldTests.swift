import Foundation
import Testing

@testable import SparkAppComposition

private func pairingViewSource() throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    return try String(
        contentsOf: appRoot.appending(path: "Shared/AdditionalDevicePairingView.swift"),
        encoding: .utf8
    )
}

private func modifiers(after field: String, in source: String) throws -> Substring {
    let start = try #require(source.range(of: "TextField(\"\(field)\""))
    return source[start.upperBound...].prefix(320)
}

/// QA-05: iOS capitalised the leading `s` of a typed `spark://pair/…` invitation, and autocorrect was free to rewrite the rest.
@Test func thePairingInvitationFieldNeitherCapitalisesNorAutocorrects() throws {
    let source = try pairingViewSource()
    let block = try modifiers(after: "Paste pairing invitation", in: source)

    #expect(block.contains(".textInputAutocapitalization(.never)"))
    #expect(block.contains(".autocorrectionDisabled()"))
}

/// QA-05: the multi-Spark package field takes the same kind of payload and had the same problem.
@Test func theMultiSparkPackageFieldNeitherCapitalisesNorAutocorrects() throws {
    let source = try pairingViewSource()
    let block = try modifiers(after: "Paste returned multi-Spark package", in: source)

    #expect(block.contains(".textInputAutocapitalization(.never)"))
    #expect(block.contains(".autocorrectionDisabled()"))
}
