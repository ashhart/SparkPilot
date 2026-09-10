import Foundation

/// Verify the bundled signed release before transfer so first install and repair work without Spark internet access.
public struct BundledReleaseSource: ReleaseSource {
    private let manifestURL: URL
    private let packageURL: URL
    private let signatureURL: URL

    public init(manifestURL: URL, packageURL: URL, signatureURL: URL) {
        self.manifestURL = manifestURL
        self.packageURL = packageURL
        self.signatureURL = signatureURL
    }

    public func manifest() async throws -> Data {
        try read(manifestURL, limit: HTTPSReleaseSource.maximumManifestBytes)
    }

    public func artifact(_ artifact: ReleaseArtifact) async throws -> Data {
        let encoded = packageURL.pathExtension == "b64"
        let packageName =
            encoded
            ? packageURL.deletingPathExtension().lastPathComponent : packageURL.lastPathComponent
        guard artifact.name == packageName else {
            throw ReleaseSourceError.transport(
                url: packageURL,
                detail: "the bundled package does not match the signed manifest"
            )
        }
        let limit = max(
            0,
            min(Int(clamping: artifact.size), HTTPSReleaseSource.maximumArtifactBytes)
        )
        guard encoded else { return try read(packageURL, limit: limit) }
        // Text encoding prevents Xcode's release resource copier from stripping the signed ar archive.
        let text = try read(packageURL, limit: ((limit + 2) / 3) * 4)
        guard let data = Data(base64Encoded: text) else {
            throw ReleaseSourceError.transport(url: packageURL, detail: "invalid bundled base64")
        }
        guard data.count <= limit else {
            throw ReleaseSourceError.tooLarge(url: packageURL, bytes: data.count, limit: limit)
        }
        return data
    }

    public func detachedSignature(_ artifact: ReleaseArtifact) async throws -> Data {
        guard signatureURL.lastPathComponent == artifact.name + ".sig" else {
            throw ReleaseSourceError.transport(
                url: signatureURL,
                detail: "the bundled signature does not match the signed manifest"
            )
        }
        return try read(signatureURL, limit: 4096)
    }

    private func read(_ url: URL, limit: Int) throws -> Data {
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resource.isRegularFile == true else {
            throw ReleaseSourceError.transport(url: url, detail: "not a regular bundled file")
        }
        if let size = resource.fileSize, size > limit {
            throw ReleaseSourceError.tooLarge(url: url, bytes: size, limit: limit)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= limit else {
            throw ReleaseSourceError.tooLarge(url: url, bytes: data.count, limit: limit)
        }
        return data
    }
}
