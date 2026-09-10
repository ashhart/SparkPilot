import Testing

@testable import SparkAppComposition

/// A fixed sequence stands in for the system generator so a chooser run is reproducible.
private struct ScriptedRandomNumberGenerator: RandomNumberGenerator {
    var values: [UInt64]
    private var index = 0

    init(_ values: [UInt64]) { self.values = values }

    mutating func next() -> UInt64 {
        defer { index += 1 }
        return values.isEmpty ? 0 : values[index % values.count]
    }
}

/// The owner asked for filler phrases while the Spark thinks, never the same one twice running.
struct SparkVoiceFillerTests {
    @Test func thePoolIsLargeEnoughAndEveryPhraseIsDistinct() {
        let pool = SparkVoiceFillers.pool
        #expect(pool.count >= 12)
        #expect(Set(pool.map(\.id)).count == pool.count)
        #expect(Set(pool.map(\.text)).count == pool.count)
        #expect(pool.allSatisfy { !$0.text.isEmpty && $0.text.count <= 80 })
        #expect(pool.allSatisfy { $0.id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." } })
    }

    @Test func theSamePhraseNeverComesBackToBackOrWithinTheLastFour() {
        var chooser = SparkVoiceFillerChooser()
        var generator = ScriptedRandomNumberGenerator([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        var chosen: [String] = []
        for _ in 0..<40 {
            let phrase = chooser.next(using: &generator)
            #expect(phrase != nil)
            guard let phrase else { break }
            let window = chosen.suffix(SparkVoiceFillerChooser.avoidLast)
            #expect(!window.contains(phrase.id))
            chosen.append(phrase.id)
        }
        #expect(chosen.count == 40)
        #expect(Set(chosen).count >= SparkVoiceFillerChooser.avoidLast + 1)
    }

    @Test func theChoiceIsDeterministicForAGivenRandomSource() {
        var first = SparkVoiceFillerChooser()
        var second = SparkVoiceFillerChooser()
        var firstGenerator = ScriptedRandomNumberGenerator([7, 3, 11, 2, 5, 13])
        var secondGenerator = ScriptedRandomNumberGenerator([7, 3, 11, 2, 5, 13])
        let left = (0..<12).compactMap { _ in first.next(using: &firstGenerator)?.id }
        let right = (0..<12).compactMap { _ in second.next(using: &secondGenerator)?.id }
        #expect(left == right)
        #expect(left.count == 12)
    }

    @Test func aSmallPoolStillAvoidsAnImmediateRepeat() {
        let pool = Array(SparkVoiceFillers.pool.prefix(2))
        var chooser = SparkVoiceFillerChooser(pool: pool)
        var generator = ScriptedRandomNumberGenerator([0])
        var previous: String?
        for _ in 0..<8 {
            let phrase = chooser.next(using: &generator)
            let identifier = phrase?.id
            #expect(phrase != nil)
            #expect(identifier != previous)
            previous = identifier
        }
    }

    @Test func anEmptyPoolChoosesNothingRatherThanTrapping() {
        var chooser = SparkVoiceFillerChooser(pool: [])
        var generator = ScriptedRandomNumberGenerator([1])
        let chosen = chooser.next(using: &generator)
        #expect(chosen == nil)
    }

    @Test func aDegenerateRandomSourceStillChoosesInsteadOfSpinningForever() {
        var chooser = SparkVoiceFillerChooser()
        var generator = ScriptedRandomNumberGenerator([0])
        for _ in 0..<20 { #expect(chooser.next(using: &generator) != nil) }
    }

    @Test func everyPhraseIsRecognisableAsAFillerAndOwnerSpeechIsNot() {
        #expect(SparkVoiceFillers.pool.allSatisfy { SparkVoiceFillers.isFiller($0.text) })
        #expect(!SparkVoiceFillers.isFiller("What is the weather on Friday?"))
        #expect(!SparkVoiceFillers.isFiller(""))
    }

    /// BH-45: the recogniser never returns the pool's own punctuation and capitals.
    @Test func theEchoGuardCatchesWhatTheRecogniserActuallyReturns() {
        let heardBack = [
            "okay let me take a look at that",
            "Okay, let me take a look at that",
            "OK, let me take a look at that.",
            "right give me a moment",
            "One second checking",
            "i am working that out now",
            "hold on I am nearly there",
        ]
        for text in heardBack {
            #expect(SparkVoiceFillers.isFiller(text), "the Spark's own filler became a question")
        }
        let questions = [
            "Let me take a look at the fabric plan",
            "Give me a moment of your time to explain the cluster",
            "What is running on the Spark right now?",
            "Check the disk space",
            "One second",
        ]
        for text in questions {
            #expect(!SparkVoiceFillers.isFiller(text), "the owner's question was swallowed")
        }
    }

    @Test func voiceSetupWarmsThePoolSoTheFirstConversationAlreadyHasOne() {
        #expect(SparkVoiceMode.conversation.warmsFillers)
        #expect(SparkVoiceMode.setup.warmsFillers)
        #expect(!SparkVoiceMode.dictation.warmsFillers)
        #expect(!SparkVoiceMode.readAloud("A reply").warmsFillers)
    }

    @Test func aVoiceChangeInvalidatesTheCachedPoolButKeepsTheSameFilenames() {
        let heart = SparkVoiceFillers.cacheName(voice: .heart, phrase: SparkVoiceFillers.pool[0])
        let fable = SparkVoiceFillers.cacheName(voice: .fable, phrase: SparkVoiceFillers.pool[0])
        #expect(heart != fable)
        #expect(heart.hasSuffix(".wav"))
        #expect(
            heart == SparkVoiceFillers.cacheName(voice: .heart, phrase: SparkVoiceFillers.pool[0])
        )
    }
}

@Test func recogniserCapitalisationAndPunctuationDoNotTurnAFillerIntoAQuestion() {
    #expect(SparkVoiceFillers.isFiller("okay let me take a look at that"))
    #expect(SparkVoiceFillers.isFiller("SURE ONE MOMENT"))
    #expect(!SparkVoiceFillers.isFiller("Sure one moment can you explain this letter"))
}
