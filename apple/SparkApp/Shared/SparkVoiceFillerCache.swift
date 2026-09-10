import Foundation

/// Pre-synthesised filler audio, so a filler starts from the device rather than a round trip.
@MainActor
final class SparkVoiceFillerCache {
    private var memory: [String: Data] = [:]
    private var preparedVoice: SparkKokoroVoice?
    private var chooser = SparkVoiceFillerChooser()
    private let directory: URL?

    init(directory: URL? = SparkVoiceFillerCache.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL? {
        try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "spark-voice-fillers", directoryHint: .isDirectory)
    }

    var isPrepared: Bool { preparedVoice != nil && !memory.isEmpty }

    /// Fill the pool for one voice, reading what is already on disk and synthesising the rest.
    func prepare(
        voice: SparkKokoroVoice,
        synthesise: (String) async throws -> Data
    ) async {
        if preparedVoice != voice { memory.removeAll() }
        preparedVoice = voice
        if let directory {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        for phrase in SparkVoiceFillers.pool {
            if Task.isCancelled { return }
            let name = SparkVoiceFillers.cacheName(voice: voice, phrase: phrase)
            if memory[phrase.id] != nil { continue }
            if let directory, let stored = try? Data(contentsOf: directory.appending(path: name)) {
                memory[phrase.id] = stored
                continue
            }
            guard let audio = try? await synthesise(phrase.text), !Task.isCancelled,
                preparedVoice == voice
            else {
                continue
            }
            memory[phrase.id] = audio
            if let directory {
                try? audio.write(to: directory.appending(path: name), options: .atomic)
            }
        }
    }

    /// The next filler to play, or nil when nothing is cached for this voice yet.
    func next(for voice: SparkKokoroVoice) -> (phrase: SparkVoiceFillerPhrase, audio: Data)? {
        guard preparedVoice == voice else { return nil }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<SparkVoiceFillers.pool.count {
            guard let phrase = chooser.next(using: &generator) else { return nil }
            if let audio = memory[phrase.id] { return (phrase, audio) }
        }
        return nil
    }

    /// Forget everything for a voice change, on disk as well, so a stale voice cannot be heard.
    func invalidate() {
        memory.removeAll()
        preparedVoice = nil
        chooser.reset()
    }
}
