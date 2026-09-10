import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class SparkShareModel {
    var text = ""
    var files: [SparkSharedFile] = []
    var loading = true
    var saved = false
    var saving = false
    var error: String?
    var loadFailed = false
    // Set when the inbox refused for being full, so the view can offer to replace the oldest pending share.
    var inboxFull = false

    func load(_ items: [NSExtensionItem]) async {
        defer { loading = false }
        do {
            let providers = items.flatMap { $0.attachments ?? [] }
            guard providers.count <= 8 else { throw SparkChatInbox.InboxError.tooLarge }
            var incoming: [SparkSharedFile] = []
            var texts: [String] = []
            for item in items {
                if let text = item.attributedContentText?.string, !text.isEmpty {
                    texts.append(text)
                }
            }
            for provider in providers {
                try Task.checkCancellation()
                let identifiers = provider.registeredTypeIdentifiers
                let fileType = identifiers.first { value in
                    guard let type = UTType(value) else { return false }
                    return type.conforms(to: .image) || type.conforms(to: .pdf)
                        || type.conforms(to: .rtf)
                        || type.preferredFilenameExtension == "docx"
                }
                if let type = fileType {
                    incoming.append(try await Self.file(provider, type: type))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    // Load a provider-owned file copy rather than retaining a temporary URL.
                    incoming.append(try await Self.fileURL(provider))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    let url = try await Self.url(provider)
                    guard ["https", "http"].contains(url.scheme?.lowercased() ?? "")
                    else { throw SparkChatInbox.InboxError.invalid }
                    texts.append(url.absoluteString)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    let text = try await Self.plainText(provider)
                    if !texts.contains(text) { texts.append(text) }
                } else {
                    throw SparkChatInbox.InboxError.invalid
                }
                guard incoming.reduce(0, { $0 + $1.data.count }) <= 20 * 1024 * 1024,
                    texts.reduce(0, { $0 + $1.utf8.count }) <= 120_000
                else { throw SparkChatInbox.InboxError.tooLarge }
            }
            try Task.checkCancellation()
            let combinedText = texts.joined(separator: "\n\n")
            guard combinedText.utf8.count <= 120_000,
                !incoming.isEmpty
                    || texts.contains(where: {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })
            else { throw SparkChatInbox.InboxError.tooLarge }
            files = incoming
            text = combinedText
        } catch is CancellationError {
        } catch {
            loadFailed = true
            self.error =
                (error as? LocalizedError)?.errorDescription
                ?? String(localized: "This shared item could not be read.")
        }
    }

    private static func url(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) {
                item,
                error in
                let url =
                    (item as? URL) ?? (item as? String).flatMap(URL.init(string:))
                    ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? SparkChatInbox.InboxError.invalid)
                }
            }
        }
    }

    private static func plainText(_ provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) {
                item,
                error in
                let text =
                    (item as? String)
                    ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                guard let text else {
                    continuation.resume(throwing: error ?? SparkChatInbox.InboxError.invalid)
                    return
                }
                guard text.utf8.count <= 120_000 else {
                    continuation.resume(throwing: SparkChatInbox.InboxError.tooLarge)
                    return
                }
                continuation.resume(returning: text)
            }
        }
    }

    private static func fileURL(_ provider: NSItemProvider) async throws -> SparkSharedFile {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                item,
                error in
                do {
                    let url =
                        (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url, url.isFileURL else {
                        throw error ?? SparkChatInbox.InboxError.invalid
                    }
                    continuation.resume(
                        returning: try readTemporaryFile(
                            url,
                            suggestedName: suggestedName,
                            type: UTType.data.identifier
                        )
                    )
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated private static func readTemporaryFile(
        _ url: URL,
        suggestedName: String?,
        type: String
    ) throws -> SparkSharedFile {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size <= 20 * 1024 * 1024
        else { throw SparkChatInbox.InboxError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 20 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 20 * 1024 * 1024 else { throw SparkChatInbox.InboxError.tooLarge }
        var name = (suggestedName ?? url.lastPathComponent) as NSString
        if name.pathExtension.isEmpty {
            let suffix =
                UTType(type)?.preferredFilenameExtension
                ?? (url.pathExtension.isEmpty ? nil : url.pathExtension)
            if let suffix { name = (name as String + "." + suffix) as NSString }
        }
        return SparkSharedFile(name: name.lastPathComponent, data: data)
    }

    private static func file(_ provider: NSItemProvider, type: String) async throws
        -> SparkSharedFile
    {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    guard let url else { throw error ?? SparkChatInbox.InboxError.invalid }
                    continuation.resume(
                        returning: try readTemporaryFile(
                            url,
                            suggestedName: suggestedName,
                            type: type
                        )
                    )
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
