import Foundation

/// One short thing the Spark says while it works out the answer.
struct SparkVoiceFillerPhrase: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
}

/// The whole spoken filler vocabulary, in one place, so it can be read and changed as copy.
enum SparkVoiceFillers {
    static let pool: [SparkVoiceFillerPhrase] = [
        .init(id: "filler.look", text: String(localized: "Okay, let me take a look at that.")),
        .init(id: "filler.think", text: String(localized: "Let me think about that for a second.")),
        .init(id: "filler.moment", text: String(localized: "Right, give me a moment.")),
        .init(
            id: "filler.understand",
            text: String(localized: "Let me try to understand this better.")
        ),
        .init(id: "filler.checking", text: String(localized: "One second, checking.")),
        .init(id: "filler.good", text: String(localized: "Good question. Give me a beat.")),
        .init(id: "filler.working", text: String(localized: "I am working that out now.")),
        .init(id: "filler.together", text: String(localized: "Let me put that together for you.")),
        .init(id: "filler.sure", text: String(localized: "Sure, one moment.")),
        .init(id: "filler.consider", text: String(localized: "Let me consider that properly.")),
        .init(id: "filler.hold", text: String(localized: "Hold on, I am nearly there.")),
        .init(
            id: "filler.interesting",
            text: String(localized: "That is interesting. Let me check.")
        ),
        .init(
            id: "filler.gathering",
            text: String(localized: "I am gathering my thoughts on that.")
        ),
        .init(id: "filler.almost", text: String(localized: "Almost ready with that one.")),
    ]

    /// How much of a heard line must match a filler; the recogniser drops a word or hears "OK" for "okay".
    static let echoMatch = 0.85

    /// True when the text is one of the spoken fillers, so it can never be mistaken for an answer.
    static func isFiller(_ text: String) -> Bool {
        let heard = words(in: text)
        guard !heard.isEmpty else { return false }
        return pool.contains { similarity(heard, words(in: $0.text)) >= echoMatch }
    }

    /// The words alone, with case, accents and punctuation removed, which the recogniser never reproduces.
    static func words(in text: String) -> [String] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        let parts = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return parts.filter { !$0.isEmpty }
    }

    /// How many words two lines share, ignoring order, over the length of the longer one.
    static func similarity(_ heard: [String], _ spoken: [String]) -> Double {
        guard !heard.isEmpty, !spoken.isEmpty else { return 0 }
        var remaining = spoken
        var shared = 0
        for word in heard {
            guard let index = remaining.firstIndex(of: word) else { continue }
            remaining.remove(at: index)
            shared += 1
        }
        return Double(shared) / Double(max(heard.count, spoken.count))
    }

    /// The cache file for one phrase in one voice; a voice change reaches a different file.
    static func cacheName(voice: SparkKokoroVoice, phrase: SparkVoiceFillerPhrase) -> String {
        voice.rawValue + "." + phrase.id + ".wav"
    }
}

/// Picks the next filler so the owner does not hear the same one twice in a row.
struct SparkVoiceFillerChooser {
    static let avoidLast = 4
    private let pool: [SparkVoiceFillerPhrase]
    private var recent: [String] = []

    init(pool: [SparkVoiceFillerPhrase] = SparkVoiceFillers.pool) {
        self.pool = pool
    }

    /// Choose from everything except the recent window, using the caller's random source.
    mutating func next(using generator: inout some RandomNumberGenerator)
        -> SparkVoiceFillerPhrase?
    {
        guard !pool.isEmpty else { return nil }
        let window = max(0, min(Self.avoidLast, pool.count - 1))
        let recentlyHeard = Set(recent.suffix(window))
        let candidates = pool.filter { !recentlyHeard.contains($0.id) }
        let choices = candidates.isEmpty ? pool : candidates
        let chosen = choices[Self.index(below: choices.count, using: &generator)]
        recent.append(chosen.id)
        if recent.count > Self.avoidLast { recent.removeFirst(recent.count - Self.avoidLast) }
        return chosen
    }

    /// Forget the history, for a fresh conversation.
    mutating func reset() { recent.removeAll() }

    /// One draw folded into range; the stdlib's unbiased draw redraws forever on a fixed source.
    private static func index(
        below count: Int,
        using generator: inout some RandomNumberGenerator
    ) -> Int {
        Int(generator.next() % UInt64(count))
    }
}
