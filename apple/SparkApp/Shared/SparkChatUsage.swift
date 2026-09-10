import Foundation

/// What the runtime counted for one turn, as the OpenAI-compatible stream reports it.
public struct SparkChatTokenUsage: Codable, Equatable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public enum SparkChatUsageTone: Equatable, Sendable {
    case normal
    case caution
    case critical
}

/// How much of the window this conversation is using, ready to read under the model's name.
public struct SparkChatContextUse: Equatable, Sendable {
    public let usedTokens: Int
    /// nil or zero means the Spark did not say, so no percentage is invented.
    public let contextLength: Int?
    public let isTruncated: Bool
    public let locale: Locale

    public init(
        usedTokens: Int,
        contextLength: Int?,
        isTruncated: Bool = false,
        locale: Locale = .autoupdatingCurrent
    ) {
        self.usedTokens = usedTokens
        self.contextLength = contextLength
        self.isTruncated = isTruncated
        self.locale = locale
    }

    public var fraction: Double? {
        guard let contextLength, contextLength > 0 else { return nil }
        return min(1, max(0, Double(usedTokens) / Double(contextLength)))
    }

    /// Rounded once, so the number shown and the tone chosen can never tell different stories.
    public var percent: Int? {
        fraction.map { Int(($0 * 100).rounded()) }
    }

    public var tone: SparkChatUsageTone {
        guard let percent else { return .normal }
        if percent >= 95 { return .critical }
        return percent >= 80 ? .caution : .normal
    }

    public var summary: String {
        let used = SparkChatUsageFormat.tokens(usedTokens, locale: locale)
        guard let contextLength, let percent, contextLength > 0 else {
            return SparkChatUsageFormat.resolve(.chatContextUsed(used), locale)
        }
        return SparkChatUsageFormat.resolve(
            .chatContextUse(
                used: used,
                limit: SparkChatUsageFormat.tokens(contextLength, locale: locale),
                percent: SparkChatUsageFormat.percent(percent, locale: locale)
            ),
            locale
        )
    }

    public var hint: String? {
        guard tone != .normal else { return nil }
        return String(localized: "Start a new chat to keep answers sharp", locale: locale)
    }

    public var truncationNote: String? {
        guard isTruncated else { return nil }
        return String(
            localized: "The last answer was cut short by the context limit.",
            locale: locale
        )
    }

    public var accessibilityValue: String {
        [summary, truncationNote, hint].compactMap { $0 }.joined(separator: ", ")
    }
}

public enum SparkChatUsageFormat {
    /// Resolve catalogue copy in a named locale so presentation maths can be tested without the device's.
    static func resolve(_ resource: LocalizedStringResource, _ locale: Locale) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    public static func tokens(_ count: Int, locale: Locale = .autoupdatingCurrent) -> String {
        guard count >= 1_000 else { return count.formatted(.number.locale(locale)) }
        return count.formatted(
            .number.notation(.compactName).precision(.fractionLength(1)).locale(locale)
        )
    }

    public static func percent(_ percent: Int, locale: Locale = .autoupdatingCurrent) -> String {
        (Double(percent) / 100).formatted(
            .percent.precision(.fractionLength(0)).locale(locale)
        )
    }

    public static func rate(_ perSecond: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let digits = perSecond >= 10 ? 0 : 1
        return perSecond.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    /// The per-response line, which counts this answer rather than the whole conversation.
    public static func responseFooter(
        for message: SparkChatMessage,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        guard let usage = message.usage else { return nil }
        let count = resolve(
            .chatResponseTokens(tokens(usage.completionTokens, locale: locale)),
            locale
        )
        guard let perSecond = message.tokensPerSecond else { return count }
        let speed = resolve(.chatResponseRate(rate(perSecond, locale: locale)), locale)
        return resolve(.joined(count, speed), locale)
    }
}

extension SparkChatMessage {
    /// Measured over the whole generation, so a slow first token is counted honestly.
    public var tokensPerSecond: Double? {
        guard let usage, usage.completionTokens > 0,
            let started = generationStartedAt,
            let ended = generationEndedAt
        else { return nil }
        let elapsed = ended.timeIntervalSince(started)
        guard elapsed > 0 else { return nil }
        return Double(usage.completionTokens) / elapsed
    }

    /// A runtime that stopped for length is telling us the window ran out.
    public var wasCutShortByContext: Bool { finishReason == "length" }
}

@MainActor
extension SparkChatModel {
    /// The conversation's context use, refreshed from whichever turn last reported usage.
    public var contextUse: SparkChatContextUse? {
        guard let answer = messages.last(where: { $0.usage != nil }), let usage = answer.usage
        else { return nil }
        return SparkChatContextUse(
            usedTokens: usage.totalTokens,
            contextLength: selectedTarget?.contextLength,
            isTruncated: answer.wasCutShortByContext
        )
    }
}
