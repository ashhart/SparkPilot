import Foundation
import SparkAPI

/// The exact body sent to a Spark: one system note first, then the conversation so far.
enum SparkChatTranscript {
    static let textBudget = 120_000
    static let imageBudget = 10 * 1024 * 1024

    static func messages(_ history: [SparkChatMessage], system: String) -> [ChatMessage] {
        [ChatMessage(role: "system", content: system)]
            + history.compactMap { message -> ChatMessage? in
                guard !message.isPartial, !message.content.isEmpty || !message.attachments.isEmpty
                else { return nil }
                let documents = message.attachments.compactMap { attachment -> String? in
                    guard let text = attachment.text else { return nil }
                    let name = String(reflecting: attachment.name)
                    return "<attachment name=\(name)>\n\(text)\n</attachment>"
                }
                let replyContext = message.role == .user ? message.replyTo?.requestContext : nil
                return ChatMessage(
                    role: message.role.rawValue,
                    content: ([replyContext, message.content].compactMap { $0 } + documents).filter
                    { !$0.isEmpty }
                    .joined(separator: "\n\n"),
                    imageDataURLs: message.attachments.compactMap(\.imageDataURL)
                )
            }
    }

    /// A conservative byte budget prevents silently clipping an attachment to fit context.
    static func fits(_ transcript: [ChatMessage], contextLength: Int?) -> Bool {
        let text = transcript.reduce(0) { $0 + $1.content.utf8.count }
        let images = transcript.flatMap(\.imageDataURLs).reduce(0) { $0 + $1.utf8.count }
        let budget = contextLength.map { max(0, $0 - 2048) } ?? textBudget
        return text <= min(textBudget, budget) && images <= imageBudget
    }
}
