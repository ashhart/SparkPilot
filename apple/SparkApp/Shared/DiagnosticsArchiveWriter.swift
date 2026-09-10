import CryptoKit
import Foundation
import SparkAPI

/// Why a bundle was not written.
public enum DiagnosticsArchiveError: Error, Equatable {
    /// The manifest does not describe the files that arrived with it.
    case manifestDisagreesWithBundle(String)
    /// The destination name is not one flat JSON basename.
    case invalidDestinationName
    /// Refuses an existing destination without opening a possible symlink or leftover file.
    case destinationExists
    /// The file could not be created, written, or made durable.
    case writeFailed(Int32)

    public var code: String {
        switch self {
        case .manifestDisagreesWithBundle: "DIAGNOSTICS_MANIFEST_MISMATCH"
        case .invalidDestinationName: "DIAGNOSTICS_DESTINATION_INVALID"
        case .destinationExists: "DIAGNOSTICS_DESTINATION_EXISTS"
        case .writeFailed: "DIAGNOSTICS_WRITE_FAILED"
        }
    }
}

/// Injects write and fsync failures to exercise interrupt retries and partial-file cleanup.
protocol DiagnosticsFileIO: Sendable {
    /// Bytes written, or a negative count with the `errno` that explains it.
    func write(
        _ descriptor: Int32,
        _ buffer: UnsafeRawPointer,
        _ count: Int
    ) -> (written: Int, errno: Int32)

    /// Zero on success, or the `errno` that explains the failure.
    func synchronize(_ descriptor: Int32) -> Int32
}

struct PosixFileIO: DiagnosticsFileIO {
    func write(
        _ descriptor: Int32,
        _ buffer: UnsafeRawPointer,
        _ count: Int
    ) -> (written: Int, errno: Int32) {
        let written = Foundation.write(descriptor, buffer, count)
        return (written, written < 0 ? errno : 0)
    }

    func synchronize(_ descriptor: Int32) -> Int32 {
        Foundation.fsync(descriptor) == 0 ? 0 : errno
    }
}

/// Creates archives exclusively at mode 0600 with symlink rejection and removes partial output after a failed write.
public struct DiagnosticsArchiveWriter: Sendable {
    private let directory: URL
    private let nextName: @Sendable () -> String
    private let fileIO: any DiagnosticsFileIO

    public init(
        directory: URL = FileManager.default.temporaryDirectory,
        // Apply the same lowercase flat-basename rule to archive names and their entries.
        nextName: @escaping @Sendable () -> String = {
            "sparkpilot-support-\(UUID().uuidString.lowercased()).json"
        }
    ) {
        self.init(directory: directory, nextName: nextName, fileIO: PosixFileIO())
    }

    init(
        directory: URL,
        nextName: @escaping @Sendable () -> String,
        fileIO: any DiagnosticsFileIO
    ) {
        self.directory = directory
        self.nextName = nextName
        self.fileIO = fileIO
    }

    /// Validate manifest contents and sensitivity labels against the files before writing an archive.
    public func write(_ bundle: GeneratedAPI.DiagnosticsBundle) throws -> URL {
        try validate(bundle)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try create(try encoder.encode(bundle))
    }

    // MARK: - Agreement

    private func validate(_ bundle: GeneratedAPI.DiagnosticsBundle) throws {
        let entries = bundle.manifest.files
        guard entries.count == bundle.files.count else {
            throw DiagnosticsArchiveError.manifestDisagreesWithBundle(
                "the manifest lists \(entries.count) files and \(bundle.files.count) arrived"
            )
        }
        var described = [String: GeneratedAPI.DiagnosticsManifestEntry]()
        for entry in entries {
            guard isFlatJSONName(entry.path) else {
                throw DiagnosticsArchiveError.manifestDisagreesWithBundle(
                    "\(entry.path) is not a flat archive entry"
                )
            }
            guard described.updateValue(entry, forKey: entry.path) == nil else {
                throw DiagnosticsArchiveError.manifestDisagreesWithBundle(
                    "\(entry.path) is described twice"
                )
            }
        }

        // Require one-to-one correspondence between manifest entries and files, not merely equal counts.
        var consumed = Set<String>()
        for file in bundle.files {
            guard let entry = described[file.path] else {
                throw DiagnosticsArchiveError.manifestDisagreesWithBundle(
                    "\(file.path) has no manifest entry"
                )
            }
            guard consumed.insert(file.path).inserted else {
                throw DiagnosticsArchiveError.manifestDisagreesWithBundle(
                    "\(file.path) arrived more than once"
                )
            }
            let bytes = Data(file.content.utf8)
            guard entry.bytes == bytes.count else {
                throw DiagnosticsArchiveError.manifestDisagreesWithBundle(
                    "\(file.path) is \(bytes.count) bytes and the manifest says \(entry.bytes)"
                )
            }
            guard entry.sha256 == Self.digest(bytes) else {
                throw DiagnosticsArchiveError.manifestDisagreesWithBundle(
                    "\(file.path) does not match its manifest digest"
                )
            }
            guard entry.sensitivity.rawValue == file.sensitivity.rawValue else {
                throw DiagnosticsArchiveError.manifestDisagreesWithBundle(
                    "\(file.path) is labelled differently in the manifest"
                )
            }
        }
        guard consumed.count == described.count else {
            throw DiagnosticsArchiveError.manifestDisagreesWithBundle(
                "\(described.count - consumed.count) described files did not arrive"
            )
        }
    }

    // MARK: - Writing

    private func create(_ data: Data) throws -> URL {
        let name = nextName()
        guard isFlatJSONName(name), !name.contains("/") else {
            throw DiagnosticsArchiveError.invalidDestinationName
        }
        let url = directory.appendingPathComponent(name)
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            throw errno == EEXIST
                ? DiagnosticsArchiveError.destinationExists
                : DiagnosticsArchiveError.writeFailed(errno)
        }
        defer { close(descriptor) }

        // Apply file protection before writing bytes; macOS relies on the owner-only POSIX mode.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )

        do {
            try emit(data, to: descriptor)
        } catch {
            // Remove partial archives so truncated contents cannot contradict the manifest.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    private func emit(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let outcome = fileIO.write(
                    descriptor,
                    base.advanced(by: written),
                    buffer.count - written
                )
                if outcome.written < 0 {
                    // Retry interrupted writes until all remaining bytes are written.
                    if outcome.errno == EINTR { continue }
                    throw DiagnosticsArchiveError.writeFailed(outcome.errno)
                }
                guard outcome.written > 0 else {
                    throw DiagnosticsArchiveError.writeFailed(EIO)
                }
                written += outcome.written
            }
        }
        // Make archive bytes durable before returning a file for the share sheet.
        var attempts = 0
        while true {
            let failure = fileIO.synchronize(descriptor)
            if failure == 0 { return }
            if failure == EINTR, attempts < 8 {
                attempts += 1
                continue
            }
            throw DiagnosticsArchiveError.writeFailed(failure)
        }
    }

    // MARK: - Names

    /// One flat archive basename: lowercase, digits, hyphen, `.json`.
    private func isFlatJSONName(_ path: String) -> Bool {
        guard path.hasSuffix(".json"), path.count <= 64 else { return false }
        let stem = path.dropLast(".json".count)
        return !stem.isEmpty
            && stem.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
