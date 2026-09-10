import Foundation
import UniformTypeIdentifiers

/// Read only the explicitly selected file into bounded text and a label without enumerating unrelated files or creating temporary copies.
public struct SparkFileAnalysisInput: Equatable, Sendable {
    /// Match the runtime text-byte limit and reject oversized input before it leaves the device.
    public static let maxBytes = 200_000
    /// Matches the runtime's `MAX_SOURCE_NAME_BYTES`.
    public static let maxSourceNameBytes = 200

    /// The decoded document.
    public let text: String
    /// Expose only a bounded leaf filename, never the owner's full path.
    public let sourceName: String

    /// Validate and extract file input with actionable intent failures.
    public static func extract(
        data: Data,
        contentType: UTType?,
        suggestedName: String?
    ) throws -> SparkFileAnalysisInput {
        guard let contentType, isSupported(contentType) else {
            throw SparkIntentError.unsupportedFileType(
                contentType?.preferredFilenameExtension ?? contentType?.identifier
            )
        }
        guard data.count <= maxBytes else {
            throw SparkIntentError.requestTooLarge(limitBytes: maxBytes)
        }
        // Verify claimed text through decoding before admitting analysis input.
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw SparkIntentError.unsupportedFileType(
                contentType.preferredFilenameExtension ?? contentType.identifier
            )
        }
        guard !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SparkIntentError.fileHasNoText
        }
        return SparkFileAnalysisInput(text: decoded, sourceName: label(from: suggestedName))
    }

    /// Accept only supported text types rather than guessing how to extract other formats.
    static func isSupported(_ type: UTType) -> Bool {
        type.conforms(to: .text) || type.conforms(to: .json) || type.conforms(to: .yaml)
    }

    /// Remove separators and bound the leaf filename before it enters prompts or operation records.
    static func label(from suggestedName: String?) -> String {
        guard let suggestedName else { return "" }
        let leaf = (suggestedName as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard leaf.utf8.count > maxSourceNameBytes else { return leaf }
        var bounded = leaf
        while bounded.utf8.count > maxSourceNameBytes {
            bounded.removeLast()
        }
        return bounded
    }
}

/// Keep pending durable analysis distinct from a finished answer at the type level.
public enum SparkAnalysisHandoff: Equatable, Sendable {
    /// Report output-ceiling truncation separately from a complete finished answer.
    case finished(text: String, truncated: Bool)
    /// The Spark is still working. The job survives this intent process.
    case running(jobID: String)

    public var isTruncated: Bool {
        if case .finished(_, let truncated) = self { return truncated }
        return false
    }
}
