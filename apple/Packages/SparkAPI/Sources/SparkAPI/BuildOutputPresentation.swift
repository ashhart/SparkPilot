import CryptoKit
import Foundation
import SparkSecurity
#if os(macOS)
    import Darwin
    import Security
#endif

enum BuildOutputRedactor {
    static func redact(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(
            of: #"/(Users|private|var|tmp)/[^\s:\"]+"#,
            with: "<local-path>",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?i)(token|password|secret|authorization)[=:]\s*[^\s]+"#,
            with: "$1=<redacted>",
            options: .regularExpression
        )
        return boundedUTF8(output, limit: 1024 * 1024)
    }

    static func boundedUTF8(_ text: String, limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var bytes = Data(text.utf8.prefix(limit))
        while String(data: bytes, encoding: .utf8) == nil, !bytes.isEmpty {
            bytes.removeLast()
        }
        return String(data: bytes, encoding: .utf8) ?? ""
    }
}

enum BuildOutputParser {
    /// PLAN 43.5: diagnostics carry the file and line they belong to, not one redacted blob.
    static func parse(
        _ output: String,
        sourceDirectory: URL? = nil
    ) -> (
        failures: [GeneratedAPI.BuildTestFailure],
        diagnostics: [GeneratedAPI.BuildDiagnostic]
    ) {
        var diagnostics: [GeneratedAPI.BuildDiagnostic] = []
        var failures: [GeneratedAPI.BuildTestFailure] = []
        for line in output.split(separator: "\n").prefix(10_000) {
            let text = String(line)
            let severity: GeneratedAPI.BuildDiagnosticSeverity?
            if text.contains(": error:") {
                severity = .error
            } else if text.contains(": warning:") {
                severity = .warning
            } else {
                severity = nil
            }
            if let severity {
                diagnostics.append(
                    diagnostic(severity: severity, line: text, sourceDirectory: sourceDirectory)
                )
            }
            if text.hasPrefix("Test Case") && text.contains("failed") {
                failures.append(
                    .init(
                        test: String(BuildOutputRedactor.redact(text).prefix(1_000)),
                        message: String(localized: "Test failed")
                    )
                )
            }
        }
        return (Array(failures.prefix(1_000)), Array(diagnostics.prefix(5_000)))
    }

    static func diagnostic(
        severity: GeneratedAPI.BuildDiagnosticSeverity,
        line text: String,
        sourceDirectory: URL?
    ) -> GeneratedAPI.BuildDiagnostic {
        guard let located = location(in: text) else {
            let redacted = BuildOutputRedactor.redact(text)
            return .init(severity: severity, message: String(redacted.suffix(16_000)))
        }
        let message = String(BuildOutputRedactor.redact(String(located.message)).suffix(16_000))
        // A line number with no file to open is noise; report the pair or neither.
        guard let file = repositoryPath(located.path, sourceDirectory: sourceDirectory) else {
            return .init(severity: severity, message: message)
        }
        return .init(
            severity: severity,
            message: message,
            file: file,
            line: located.line,
            column: located.column
        )
    }

    /// Split `path:line:column: severity: message` without disturbing the message's own colons.
    static func location(
        in text: String
    ) -> (path: String, line: Int, column: Int, message: Substring)? {
        let marker = text.range(of: ": error: ") ?? text.range(of: ": warning: ")
        guard let marker else { return nil }
        let head = text[..<marker.lowerBound]
        let parts = head.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
            let column = Int(parts[parts.count - 1]),
            let line = Int(parts[parts.count - 2]),
            line > 0, column > 0
        else { return nil }
        let path = parts.dropLast(2).joined(separator: ":")
        guard !path.isEmpty else { return nil }
        return (path, line, column, text[marker.upperBound...])
    }

    /// A path inside the checkout is reported relative to it; anything else is not reported at all.
    static func repositoryPath(_ path: String, sourceDirectory: URL?) -> String? {
        guard let root = sourceDirectory?.standardizedFileURL.path, !root.isEmpty else {
            return nil
        }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }
}

extension String {
    func isBuildLowercaseHex(count: Int) -> Bool {
        self.count == count
            && utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}
