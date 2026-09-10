import Foundation
import Testing

@testable import SparkAPI

private let checkout = URL(fileURLWithPath: "/Users/builder/work/job-1/checkout")

/// PLAN 43.5 returns compiler diagnostics mapped to files and lines.
@Test func aCompilerErrorCarriesItsFileLineAndColumn() {
    let output = """
        /Users/builder/work/job-1/checkout/Sources/App/Model.swift:42:17: error: cannot find 'foo' in scope
        """
    let parsed = BuildOutputParser.parse(output, sourceDirectory: checkout)

    let diagnostic = try? #require(parsed.diagnostics.first)
    #expect(diagnostic?.severity == .error)
    #expect(diagnostic?.file == "Sources/App/Model.swift")
    #expect(diagnostic?.line == 42)
    #expect(diagnostic?.column == 17)
    #expect(diagnostic?.message == "cannot find 'foo' in scope")
}

/// The worker's own directory layout is not part of the answer, only the repository path is.
@Test func theWorkersAbsolutePathNeverReachesTheOwner() {
    let output = """
        /Users/builder/work/job-1/checkout/Sources/App/Model.swift:42:17: error: bad
        """
    let parsed = BuildOutputParser.parse(output, sourceDirectory: checkout)

    #expect(parsed.diagnostics.first?.file?.contains("/Users/builder") == false)
    #expect(parsed.diagnostics.first?.message.contains("/Users/builder") == false)
}

/// A path outside the checkout is reported as no path at all rather than as a local one.
@Test func aDiagnosticOutsideTheCheckoutReportsNoFile() {
    let output = """
        /Users/builder/Library/Toolchains/x.swift:9:3: warning: deprecated
        """
    let parsed = BuildOutputParser.parse(output, sourceDirectory: checkout)

    #expect(parsed.diagnostics.first?.severity == .warning)
    #expect(parsed.diagnostics.first?.file == nil)
    #expect(parsed.diagnostics.first?.line == nil)
}

/// A diagnostic with no location still reports its message, as it did before.
@Test func aDiagnosticWithNoLocationKeepsItsMessage() {
    let parsed = BuildOutputParser.parse(
        "xcodebuild: error: Scheme Spark is not configured for running.",
        sourceDirectory: checkout
    )

    #expect(parsed.diagnostics.count == 1)
    #expect(parsed.diagnostics.first?.file == nil)
    #expect(parsed.diagnostics.first?.message.contains("not configured") == true)
}

/// A message with colons of its own is not mistaken for a location.
@Test func aMessageContainingColonsIsNotReadAsALocation() {
    let output = """
        /Users/builder/work/job-1/checkout/a.swift:3:1: error: expected ':' after 'case'
        """
    let parsed = BuildOutputParser.parse(output, sourceDirectory: checkout)

    #expect(parsed.diagnostics.first?.file == "a.swift")
    #expect(parsed.diagnostics.first?.line == 3)
    #expect(parsed.diagnostics.first?.message == "expected ':' after 'case'")
}

/// A secret on a diagnostic line is still redacted even though the line is now parsed.
@Test func aSecretOnADiagnosticLineIsStillRemoved() {
    let output = """
        /Users/builder/work/job-1/checkout/a.swift:1:1: error: token=abcdef123 rejected
        """
    let parsed = BuildOutputParser.parse(output, sourceDirectory: checkout)

    #expect(parsed.diagnostics.first?.message.contains("abcdef123") == false)
    #expect(parsed.diagnostics.first?.message.contains("<redacted>") == true)
}

/// Without a known checkout nothing is guessed about where a file lives.
@Test func withNoSourceDirectoryNoPathIsReported() {
    let output = """
        /Users/builder/work/job-1/checkout/a.swift:1:1: error: bad
        """
    let parsed = BuildOutputParser.parse(output)

    #expect(parsed.diagnostics.first?.file == nil)
    #expect(parsed.diagnostics.first?.line == nil)
    #expect(parsed.diagnostics.first?.message == "bad")
}
