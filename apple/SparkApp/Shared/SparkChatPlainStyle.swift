import Foundation

/// What "plain style" asks a model for, and the phrases the post-processor removes when it is ignored.
enum SparkChatPlainStyle {
    static let sectionName = "plain-style"

    /// Kept short so it costs little of a small context window.
    static let instruction = """
        Write in plain, direct prose. Answer the question first, then add only what is needed.
        Never use an em dash or an en dash as a separator: use a comma, a colon or a full stop.
        No opening or closing filler, such as "Certainly", "Great question", "I hope this helps"
        or "Let me know if". No hedging boilerplate, no "As an AI" disclaimers, no emoji unless
        the owner asks. Prefer a sentence to a bullet list when a sentence will do.
        """

    static func section(isEnabled: Bool) -> SparkChatInstructionSection {
        SparkChatInstructionSection(name: sectionName, text: isEnabled ? instruction : "")
    }

    /// Openers removed when they start a paragraph, matched case-insensitively up to their punctuation.
    static let openers = [
        "certainly",
        "of course",
        "sure thing",
        "sure",
        "absolutely",
        "great question",
        "good question",
        "excellent question",
        "that is a great question",
        "that's a great question",
        "what a great question",
        "i'd be happy to help",
        "i would be happy to help",
        "happy to help",
        "as an ai language model",
        "as an ai",
        "i'm just an ai",
        "let me break this down",
        "let's dive in",
    ]

    /// Closers removed when they are the whole last sentence of a paragraph.
    static let closers = [
        "i hope this helps",
        "i hope that helps",
        "hope this helps",
        "hope that helps",
        "let me know if",
        "let me know how",
        "just let me know",
        "please let me know",
        "feel free to ask",
        "feel free to let me know",
        "if you have any questions",
        "if you have any other questions",
        "happy to help",
        "i hope this is helpful",
    ]
}
