import Foundation

/// Rejects unsuitable catalogue files before upload for usability; only runtime signature verification establishes trust.
enum SparkCatalogueFileGate {
    /// Require a minimally plausible JSON size and cap file mapping before parsing catalogues.
    static let permittedByteRange = 2...(2 * 1024 * 1024)

    enum Rejection: Error, Equatable {
        /// A directory, a symlink, a device, or a file outside the size range.
        case unusableFile
        /// Read as bytes but not as UTF-8 text.
        case notUTF8
        /// The bytes could not be read at all.
        case unreadable
        /// The picker itself failed.
        case unopenable

        var message: String {
            switch self {
            case .unusableFile:
                String(localized: "Choose a regular UTF-8 catalogue JSON file up to 2 MB.")
            case .notUTF8:
                String(localized: "Choose a UTF-8 signed catalogue JSON file up to 2 MB.")
            case .unreadable:
                String(localized: "The catalogue file could not be read.")
            case .unopenable:
                String(localized: "The catalogue file could not be opened.")
            }
        }
    }

    /// Rejects unsuitable file metadata before reading bytes, returning nil when the file is worth reading.
    static func inspect(isRegularFile: Bool?, fileSizeBytes: Int?) -> Rejection? {
        guard isRegularFile == true,
            let size = fileSizeBytes,
            permittedByteRange.contains(size)
        else { return .unusableFile }
        return nil
    }

    static func decode(_ data: Data) -> Result<String, Rejection> {
        guard let json = String(data: data, encoding: .utf8) else { return .failure(.notUTF8) }
        return .success(json)
    }
}
