import Foundation

public struct SparkSharedFile: Codable, Equatable, Sendable {
    public let name: String
    public let data: Data
    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public struct SparkSharedChat: Codable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let text: String
    public let files: [SparkSharedFile]
    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String, files: [SparkSharedFile])
    {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.files = files
    }
}

/// Let the share extension publish immutable envelopes atomically without access to inference credentials or device identity.
public struct SparkChatInbox: Sendable {
    public static let groupID = "group.com.sparkpilot.chat"
    public static let maximumEnvelopeBytes = 30 * 1024 * 1024
    public let directory: URL

    public init(directory: URL) { self.directory = directory }
    public static func shared() throws -> Self {
        guard
            let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupID
            )
        else { throw InboxError.unavailable }
        return Self(directory: root.appendingPathComponent("ChatInbox", isDirectory: true))
    }

    public func enqueue(_ share: SparkSharedChat, replacingOldestWhenFull: Bool = false) throws {
        try validate(share)
        let fm = FileManager.default
        try fm.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        try coordinatedWrite {
            let queued = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            if queued.count >= 10 {
                // The extension may trade the oldest pending share for this one when the owner asks.
                guard replacingOldestWhenFull, let oldest = Self.byAge(queued).first else {
                    throw InboxError.full
                }
                try fm.removeItem(at: oldest)
            }
            let data = try JSONEncoder().encode(share)
            guard data.count <= Self.maximumEnvelopeBytes else { throw InboxError.tooLarge }
            let destination = directory.appendingPathComponent(share.id.uuidString + ".json")
            guard !fm.fileExists(atPath: destination.path) else { throw InboxError.invalid }
            #if os(iOS)
                try data.write(to: destination, options: [.atomic, .completeFileProtection])
            #else
                try data.write(to: destination, options: .atomic)
            #endif
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    private func coordinatedWrite(_ action: () throws -> Void) throws {
        var coordinationError: NSError?
        var result: Result<Void, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: directory,
            options: .forMerging,
            error: &coordinationError
        ) { _ in
            result = Result { try action() }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw InboxError.invalid }
        try result.get()
    }

    private static func byAge(_ urls: [URL]) -> [URL] {
        urls.sorted {
            let left =
                (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right =
                (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left == right ? $0.lastPathComponent < $1.lastPathComponent : left < right
        }
    }

    /// Return the oldest readable share; an unreadable envelope is set aside so it cannot block the ones behind it.
    public func next() throws -> SparkSharedChat? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let urls = Self.byAge(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey,
                ]
            ).filter { $0.pathExtension == "json" }
        )
        for url in urls {
            do {
                return try read(url)
            } catch {
                try quarantine(url)
            }
        }
        return nil
    }

    private func read(_ url: URL) throws -> SparkSharedChat {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size <= Self.maximumEnvelopeBytes
        else { throw InboxError.invalid }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: Self.maximumEnvelopeBytes + 1) ?? Data()
        guard data.count <= Self.maximumEnvelopeBytes else { throw InboxError.tooLarge }
        let share = try JSONDecoder().decode(SparkSharedChat.self, from: data)
        guard url.lastPathComponent == share.id.uuidString + ".json" else {
            throw InboxError.invalid
        }
        try validate(share)
        return share
    }

    private func quarantine(_ url: URL) throws {
        let destination = url.deletingPathExtension().appendingPathExtension("unreadable")
        try coordinatedWrite {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: url, to: destination)
        }
    }

    /// Envelopes set aside because they could not be read; the owner may remove them without touching readable shares.
    public func unreadableCount() -> Int {
        let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return (entries ?? []).filter { $0.pathExtension == "unreadable" }.count
    }

    public func discardUnreadableShares() throws {
        try coordinatedWrite {
            for url in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            where url.pathExtension == "unreadable" {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public func remove(id: UUID) throws {
        try coordinatedWrite {
            let url = directory.appendingPathComponent(id.uuidString + ".json")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Explicit recovery when a malformed envelope is blocking the inbox.
    public func discardPendingShares() throws {
        try coordinatedWrite {
            for url in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            where ["json", "unreadable"].contains(url.pathExtension) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func validate(_ share: SparkSharedChat) throws {
        guard share.files.count <= 8, share.text.utf8.count <= 120_000,
            share.files.allSatisfy({
                !$0.name.isEmpty && $0.name.utf8.count <= 255 && !$0.name.contains("/")
                    && !$0.name.contains("\\") && $0.data.count <= 20 * 1024 * 1024
            }),
            share.files.reduce(0, { $0 + $1.data.count }) <= 20 * 1024 * 1024,
            !share.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !share.files.isEmpty
        else { throw InboxError.tooLarge }
    }

    public enum InboxError: LocalizedError, Sendable {
        case unavailable, full, tooLarge, invalid
        public var errorDescription: String? {
            switch self {
            case .unavailable:
                String(
                    localized:
                        "Sharing is unavailable in this build; import the file from chat instead."
                )
            case .full:
                String(localized: "Open SparkPilot and review pending shares before adding more.")
            case .tooLarge:
                String(
                    localized:
                        "Share up to eight files totalling 20 MB and no more than 120 KB of text."
                )
            case .invalid: String(localized: "This shared item could not be read.")
            }
        }
    }
}
