import Foundation

/// Every timing the conversation depends on, in one place so a change is one edit and one test.
enum SparkVoiceTurnTiming {
    /// A 0…1 level at or above this counts as the owner speaking.
    static let speechLevel = 0.12
    /// Speech has to last this long before a pause is allowed to end the turn.
    static let minimumSpeech = 0.6
    /// Silence this long after enough speech ends the turn; a mid-sentence breath survives it.
    static let endOfTurnSilence = 1.4
    /// Give up on a turn that never contained speech after this much silence.
    static let noSpeechTimeout = 6.0
    /// A turn is cut here so a stuck microphone cannot hold the conversation open.
    static let maximumTurn = 35.0
    /// A cached filler starts this soon after the turn ends, unless the answer beat it there.
    static let fillerDelay = 0.3
    /// Speech has to clear this higher level to interrupt the Spark while it is speaking.
    static let bargeInLevel = 0.3
    /// And it has to hold for this long, so one door slam is not an interruption.
    static let bargeInSpeech = 0.4
    /// The largest gap between two samples that may be credited as continuous speech.
    static let maximumSampleGap = 0.25
    /// A recogniser reports itself unavailable until it connects; poll this often, this many times.
    static let recogniserPoll = 0.2
    static let recogniserAttempts = 10
}

/// Decides when the owner has finished a turn, from levels and a clock the caller supplies.
struct SparkVoiceTurnDetector {
    enum Outcome: Equatable {
        case waiting, hearing, endOfTurn, heardNothing, tooLong
    }

    private var startedAt: Double?
    private var lastSampleAt: Double?
    private var lastSpeechAt: Double?
    private var wasSpeaking = false
    private var speechSeconds = 0.0

    init() {}

    /// Feed one level sample taken at `now`, in seconds on any monotonic timeline.
    mutating func observe(level: Double, at now: Double) -> Outcome {
        let start = startedAt ?? now
        startedAt = start
        let speaking = level >= SparkVoiceTurnTiming.speechLevel
        if speaking {
            if wasSpeaking, let previous = lastSampleAt, now > previous {
                speechSeconds += min(now - previous, SparkVoiceTurnTiming.maximumSampleGap)
            }
            lastSpeechAt = now
        }
        wasSpeaking = speaking
        lastSampleAt = now
        if now - start >= SparkVoiceTurnTiming.maximumTurn { return .tooLong }
        if speechSeconds >= SparkVoiceTurnTiming.minimumSpeech, let heard = lastSpeechAt,
            now - heard >= SparkVoiceTurnTiming.endOfTurnSilence
        {
            return .endOfTurn
        }
        if speechSeconds < SparkVoiceTurnTiming.minimumSpeech,
            now - (lastSpeechAt ?? start) >= SparkVoiceTurnTiming.noSpeechTimeout
        {
            return .heardNothing
        }
        return speaking ? .hearing : .waiting
    }

    /// Forget the previous turn so the same detector can run the next one.
    mutating func reset() {
        startedAt = nil
        lastSampleAt = nil
        lastSpeechAt = nil
        wasSpeaking = false
        speechSeconds = 0
    }
}

/// Decides when the owner is talking over the Spark, from levels alone so nothing is transcribed.
struct SparkVoiceBargeInDetector {
    private var lastSampleAt: Double?
    private var wasSpeaking = false
    private var speechSeconds = 0.0

    init() {}

    /// Returns true once speech has held above the barge-in level for long enough to interrupt.
    mutating func observe(level: Double, at now: Double) -> Bool {
        let speaking = level >= SparkVoiceTurnTiming.bargeInLevel
        if speaking {
            if wasSpeaking, let previous = lastSampleAt, now > previous {
                speechSeconds += min(now - previous, SparkVoiceTurnTiming.maximumSampleGap)
            }
        } else {
            speechSeconds = 0
        }
        wasSpeaking = speaking
        lastSampleAt = now
        return speechSeconds >= SparkVoiceTurnTiming.bargeInSpeech
    }

    /// Forget the run so the next reply starts from silence.
    mutating func reset() {
        lastSampleAt = nil
        wasSpeaking = false
        speechSeconds = 0
    }
}
