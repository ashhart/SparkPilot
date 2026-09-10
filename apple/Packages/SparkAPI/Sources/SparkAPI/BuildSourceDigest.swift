import CryptoKit
import Foundation
import SparkSecurity
#if os(macOS)
    import Darwin
    import Security
#endif

public enum BuildSourceDigest {
    public static func hex(of root: URL, byteLimit: Int) throws -> String {
        var hasher = SHA256()
        var total = 0
        for (file, relative) in try regularFiles(in: root) {
            let declaredSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard declaredSize >= 0, declaredSize <= byteLimit - total else {
                throw BuildWorkerExecutionError.sourceTooLarge
            }
            let bytes = try Data(contentsOf: file, options: [.mappedIfSafe])
            total += bytes.count
            guard total <= byteLimit else { throw BuildWorkerExecutionError.sourceTooLarge }
            hasher.update(data: Data(relative.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: bytes)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func allocatedBytes(in root: URL) throws -> Int {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []
            )
        else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
        }
        return total
    }

    private static func regularFiles(in root: URL) throws -> [(URL, String)] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        else { return [] }
        var files: [(URL, String)] = []
        for case let file as URL in enumerator {
            let level = enumerator.level
            if level == 1, file.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw BuildWorkerExecutionError.sourceDigestMismatch
            }
            if values.isRegularFile == true {
                files.append((file, file.pathComponents.suffix(level).joined(separator: "/")))
            }
        }
        return files.sorted { $0.1 < $1.1 }
    }
}
