import Foundation

/// Keep the signed Debian revision through discovery, transfer and update comparison.
public enum RuntimeReleaseIdentity {
    public static func releaseID(manifest: ReleaseManifest, artifact: ReleaseArtifact) -> String {
        let prefix = "spark-runtime_"
        let suffix = "_arm64.deb"
        var version = manifest.version
        if artifact.name.hasPrefix(prefix), artifact.name.hasSuffix(suffix) {
            let packaged = String(artifact.name.dropFirst(prefix.count).dropLast(suffix.count))
            if packaged.hasPrefix(manifest.version + "-"),
                ReleaseManifest.isReleaseVersion(packaged)
            {
                version = packaged
            }
        }
        return "\(manifest.channel)-\(version)"
    }

    /// A legacy base-only identity sorts before a packaged revision of that same runtime.
    public static func compare(releaseID: String?, installedVersion: String?) -> ComparisonResult? {
        guard let releaseID, let installedVersion,
            let separator = releaseID.firstIndex(of: "-"),
            ["dev", "lab", "beta", "stable"].contains(String(releaseID[..<separator]))
        else { return nil }
        let bundled = String(releaseID[releaseID.index(after: separator)...])
        guard ReleaseManifest.isReleaseVersion(bundled),
            ReleaseManifest.isReleaseVersion(installedVersion)
        else { return nil }
        let left = parts(bundled)
        let right = parts(installedVersion)
        let core = comparePart(left.core, right.core)
        return core == .orderedSame ? comparePart(left.revision, right.revision) : core
    }

    private static func parts(_ value: String) -> (core: String, revision: String) {
        let version = value.split(separator: "+", maxSplits: 1)[0]
        guard let separator = version.lastIndex(of: "-") else { return (String(version), "0") }
        return (String(version[..<separator]), String(version[version.index(after: separator)...]))
    }

    // Debian compares digit runs numerically, letters before punctuation, and an exhausted run first.
    private static func comparePart(_ left: String, _ right: String) -> ComparisonResult {
        let a = Array(left.utf8)
        let b = Array(right.utf8)
        var i = 0
        var j = 0
        func digit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
        func order(_ bytes: [UInt8], _ index: Int) -> Int {
            guard index < bytes.count else { return 0 }
            let byte = bytes[index]
            if digit(byte) { return 0 }
            return (65...90).contains(byte) || (97...122).contains(byte)
                ? Int(byte) : Int(byte) + 256
        }
        while i < a.count || j < b.count {
            while (i < a.count && !digit(a[i])) || (j < b.count && !digit(b[j])) {
                let x = order(a, i)
                let y = order(b, j)
                if x != y { return x < y ? .orderedAscending : .orderedDescending }
                if i < a.count { i += 1 }
                if j < b.count { j += 1 }
            }
            while i < a.count && a[i] == 48 { i += 1 }
            while j < b.count && b[j] == 48 { j += 1 }
            var difference = 0
            while i < a.count && j < b.count && digit(a[i]) && digit(b[j]) {
                if difference == 0 { difference = Int(a[i]) - Int(b[j]) }
                i += 1
                j += 1
            }
            if i < a.count && digit(a[i]) { return .orderedDescending }
            if j < b.count && digit(b[j]) { return .orderedAscending }
            if difference != 0 { return difference < 0 ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
