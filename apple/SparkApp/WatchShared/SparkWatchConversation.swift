import Foundation

public enum SparkWatchConversation {
    public static func appending(_ text: String, to messages: [SparkWatchMessage]) throws
        -> [SparkWatchMessage]
    {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16_384 else {
            throw SparkWatchFailure("Enter a shorter message to send from your watch.")
        }
        // A recovered reply has no persisted prompt; begin a new context after it.
        var history = messages.first?.role == .user ? messages : []
        if history.last?.role == .user { history.removeLast() }
        while history.count >= 14
            || history.reduce(0, { $0 + $1.text.utf8.count }) + text.utf8.count > 16_384
        {
            guard history.count >= 2 else { break }
            history.removeFirst(2)
        }
        history.append(.init(role: .user, text: text))
        return history
    }
}
