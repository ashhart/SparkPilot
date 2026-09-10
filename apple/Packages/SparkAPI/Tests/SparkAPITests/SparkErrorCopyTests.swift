import Foundation
import Testing

@testable import SparkAPI

/// Read the contract itself so a code added to the document cannot ship without owner copy.
private func documentedErrorCodes(_ file: String = #filePath) throws -> [String] {
    var root = URL(fileURLWithPath: file).deletingLastPathComponent()
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let contract = root.appending(path: "docs/ERROR_CODES.md")
    let text = try String(contentsOf: contract, encoding: .utf8)
    var codes: [String] = []
    for line in text.split(separator: "\n") where line.hasPrefix("| ") {
        let cell = line.dropFirst(2).prefix { $0 != "|" }.trimmingCharacters(in: .whitespaces)
        let isCode =
            !cell.isEmpty
            && cell.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
        if isCode { codes.append(cell) }
    }
    return codes
}

@Test func theContractIsReadableFromTheTest() throws {
    let codes = try documentedErrorCodes()
    #expect(codes.count > 90)
    #expect(codes.contains("MODEL_INSUFFICIENT_MEMORY"))
    #expect(codes.contains("OPERATION_LEASE_EXPIRED"))
}

@Test func everyDocumentedCodeHasOwnerFacingCopy() throws {
    var missing: [String] = []
    for code in try documentedErrorCodes() {
        // Two codes are answered by their own dedicated screens rather than a message.
        if ["PROTOCOL_UNSUPPORTED", "DEVICE_NOT_PAIRED"].contains(code) { continue }
        if SparkErrorCopy.message(for: code) == nil { missing.append(code) }
    }
    #expect(missing.isEmpty, "codes with no owner copy: \(missing.joined(separator: ", "))")
}

@Test func ownerCopyNeverEchoesTheCodeOrAnInternalTerm() throws {
    let banned = ["docker", "vllm", "systemd", "nftables", "cgroup", "sqlite"]
    for code in try documentedErrorCodes() {
        guard let message = SparkErrorCopy.message(for: code) else { continue }
        #expect(!message.contains(code), "\(code) copy repeats the code")
        for term in banned {
            #expect(
                !message.localizedCaseInsensitiveContains(term),
                "\(code) copy names \(term)"
            )
        }
    }
}

@Test func aReportedRefusalUsesTheDocumentedCopyInsteadOfTheBareCode() {
    let error = APIError(.reported, statusCode: 401, code: "CLOCK_SKEW_TOO_LARGE")
    let message = APIError.message(for: error)
    #expect(message.contains("clock"))
    #expect(!message.contains("CLOCK_SKEW_TOO_LARGE"))
}

@Test func anUndocumentedCodeStillFallsBackToTheServerSafeForm() {
    let error = APIError(.reported, statusCode: 500, code: "SOMETHING_NEW")
    #expect(APIError.message(for: error).contains("SOMETHING_NEW"))
}
