import Foundation

enum SparkFeedbackKind: String, Codable, CaseIterable, Identifiable {
    case bug, feedback, feature
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bug: String(localized: "Bug report")
        case .feedback: String(localized: "Feedback")
        case .feature: String(localized: "Feature request")
        }
    }
    var subject: String { title }
    var prompt: String {
        switch self {
        case .bug: String(localized: "What happened?")
        case .feedback: String(localized: "What would you like to tell us?")
        case .feature: String(localized: "What would you like SparkPilot to do?")
        }
    }
}

struct SparkBugDraft: Codable, Equatable {
    var kind = SparkFeedbackKind.bug
    var happened = ""
    var steps = ""
    var hasContent: Bool { !happened.isEmpty || !steps.isEmpty }
    var canReview: Bool {
        !happened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && happened.utf8.count <= 16_384 && (kind != .bug || steps.utf8.count <= 16_384)
    }
}

struct SparkBugReport: Identifiable {
    let id = UUID()
    let recipient: String?
    let subject: String
    let body: String
    let screenshot: SparkBugScreenshot?

    init(draft: SparkBugDraft, screenshot: SparkBugScreenshot?, recipient: String?) {
        self.recipient = SparkBugFeedbackConfiguration.validatedEmail(recipient)
        subject = draft.kind.subject
        self.screenshot = screenshot
        var sections = [
            "\(draft.kind.prompt)\n\(draft.happened.trimmingCharacters(in: .whitespacesAndNewlines))"
        ]
        if draft.kind == .bug, !draft.steps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            sections.append(
                [String(localized: "How to reproduce it"), draft.steps].joined(separator: "\n")
            )
        }
        body = sections.joined(separator: "\n\n")
    }
}

enum SparkBugFeedbackConfiguration {
    static var recipient: String? {
        validatedEmail(Bundle.main.object(forInfoDictionaryKey: "SparkFeedbackEmail") as? String)
    }

    static func validatedEmail(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 254, !value.isEmpty,
            value.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }),
            value.rangeOfCharacter(from: .controlCharacters) == nil,
            !value.contains(where: { ",;<>?&#%:".contains($0) }),
            !value.unicodeScalars.contains(where: { $0.value == 34 || $0.value == 92 })
        else { return nil }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.count <= 64,
            parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
            parts[1].allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
            })
        else { return nil }
        return value
    }
}
