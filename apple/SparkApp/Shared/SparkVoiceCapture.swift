@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

@MainActor
final class SparkVoiceCapture {
    enum Failure: Error, Equatable {
        case permission(SparkVoicePermission)
        case audioUnavailable
        case recognitionUnavailable
        case noSpeech
        case tooLong
    }

    enum Mode: Equatable { case turn, bargeIn }

    private let now: @Sendable () -> Double
    private let allowsAppleServers: @Sendable () -> Bool
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recordingID: UUID?
    private var transcript = ""
    private var detector = SparkVoiceTurnDetector()
    private var bargeIn = SparkVoiceBargeInDetector()
    private var completion: ((Result<String, any Error>) -> Void)?
    private var interrupted: (() -> Void)?
    private(set) var isEchoCancelling = false

    init(
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        allowsAppleServers: @escaping @Sendable () -> Bool = {
            SparkVoiceRecognitionPolicy.allowsAppleServers()
        }
    ) {
        self.now = now
        self.allowsAppleServers = allowsAppleServers
    }

    /// Ask for both permissions off the main actor; TCC always answers on a background queue.
    static func permission(requesting: Bool) async -> SparkVoicePermission {
        let microphone =
            requesting
            ? await requestMicrophone() : AVCaptureDevice.authorizationStatus(for: .audio)
        guard microphone == .authorized else {
            return microphone == .notDetermined ? .notDetermined : .microphoneDenied
        }
        let speech = requesting ? await requestSpeech() : SFSpeechRecognizer.authorizationStatus()
        switch speech {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .restricted: return .speechRestricted
        default: return .speechDenied
        }
    }

    private nonisolated static func requestMicrophone() async -> AVAuthorizationStatus {
        await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied
    }

    /// Nonisolated so the reply closure carries no actor check; TCC calls it on its own queue.
    private nonisolated static func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Nonisolated for the same reason: `AVAudioEngine` calls a tap on its render thread.
    private nonisolated static func installTap(
        on node: AVAudioInputNode,
        format: AVAudioFormat,
        bufferSize: UInt32,
        appending request: SFSpeechAudioBufferRecognitionRequest?,
        level: @escaping @Sendable (Double) -> Void
    ) {
        node.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            request?.append(buffer)
            level(rootMeanSquare(of: buffer))
        }
    }

    private nonisolated static func rootMeanSquare(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var energy: Float = 0
        for index in 0..<Int(buffer.frameLength) { energy += samples[index] * samples[index] }
        return Double(sqrt(energy / Float(buffer.frameLength)))
    }

    /// Nonisolated because `SFSpeechRecognizer` reports results on a private queue.
    private nonisolated static func recognise(
        _ recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        report: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            report(result?.bestTranscription.formattedString, result?.isFinal == true, error != nil)
        }
    }

    /// Start a listening turn. Throws instead of trapping when audio or recognition is unusable.
    func start(
        partial: @escaping @MainActor (String, Double) -> Void,
        completion: @escaping @MainActor (Result<String, any Error>) -> Void
    ) async throws {
        stop()
        let id = UUID()
        recordingID = id
        let permission = await Self.permission(requesting: true)
        guard recordingID == id, !Task.isCancelled else { throw CancellationError() }
        guard permission == .granted else { throw Failure.permission(permission) }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw Failure.recognitionUnavailable
        }
        let mode = SparkVoiceRecognitionPolicy.mode(
            supportsOnDevice: recognizer.supportsOnDeviceRecognition,
            allowsAppleServers: allowsAppleServers()
        )
        guard mode.isPermitted else { throw Failure.recognitionUnavailable }
        guard await Self.waitForRecogniser(recognizer, mode: mode) else {
            throw Failure.recognitionUnavailable
        }
        guard recordingID == id, !Task.isCancelled else { throw CancellationError() }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = mode.requiresOnDeviceRecognition
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        self.completion = completion
        transcript = ""
        detector.reset()
        try startEngine(mode: .turn, id: id, partial: partial)
        task = Self.recognise(recognizer, request: request) { [weak self] text, final, failed in
            Task { @MainActor [weak self] in
                self?.received(text: text, final: final, failed: failed, id: id, partial: partial)
            }
        }
    }

    static func recognitionRequest(supportsOnDevice: Bool) throws
        -> SFSpeechAudioBufferRecognitionRequest
    {
        guard supportsOnDevice else { throw Failure.recognitionUnavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        return request
    }

    /// A recogniser answers `isAvailable` false until it connects, so give it a moment first.
    private static func waitForRecogniser(
        _ recognizer: SFSpeechRecognizer,
        mode: SparkVoiceRecognitionMode
    ) async -> Bool {
        for _ in 0..<SparkVoiceTurnTiming.recogniserAttempts {
            guard !Task.isCancelled else { return false }
            if isReady(recognizer, mode: mode) { return true }
            do { try await Task.sleep(for: .seconds(SparkVoiceTurnTiming.recogniserPoll)) } catch {
                return false
            }
        }
        return isReady(recognizer, mode: mode)
    }

    /// On-device only means a reachable server recogniser is not a reason to start.
    private static func isReady(
        _ recognizer: SFSpeechRecognizer,
        mode: SparkVoiceRecognitionMode
    ) -> Bool {
        guard !mode.requiresOnDeviceRecognition else {
            return recognizer.supportsOnDeviceRecognition
        }
        return recognizer.supportsOnDeviceRecognition || recognizer.isAvailable
    }

    /// Watch the room for the owner talking over the Spark. No recogniser, so nothing is transcribed.
    func startBargeIn(onSpeech: @escaping @MainActor () -> Void) throws {
        stop()
        let id = UUID()
        recordingID = id
        interrupted = onSpeech
        bargeIn.reset()
        try startEngine(mode: .bargeIn, id: id, partial: { _, _ in })
    }

    private func startEngine(
        mode: Mode,
        id: UUID,
        partial: @escaping @MainActor (String, Double) -> Void
    ) throws {
        do {
            try SparkVoiceAudioSession.activate(.conversation)
        } catch {
            stop()
            throw Failure.audioUnavailable
        }
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        isEchoCancelling =
            (try? input.setVoiceProcessingEnabled(true)) != nil
            && input.isVoiceProcessingEnabled
        let format = input.outputFormat(forBus: 0)
        guard
            SparkVoiceAudioFormat.isUsable(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            )
        else {
            stop()
            throw Failure.audioUnavailable
        }
        Self.installTap(
            on: input,
            format: format,
            bufferSize: SparkVoiceAudioFormat.tapBufferSize(sampleRate: format.sampleRate),
            appending: mode == .turn ? request : nil
        ) { [weak self] value in
            Task { @MainActor [weak self] in
                self?.sampled(
                    SparkVoiceAudioFormat.level(rootMeanSquare: value),
                    id: id,
                    mode: mode,
                    partial: partial
                )
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw Failure.audioUnavailable
        }
    }

    private func sampled(
        _ level: Double,
        id: UUID,
        mode: Mode,
        partial: @escaping @MainActor (String, Double) -> Void
    ) {
        guard recordingID == id else { return }
        let instant = now()
        guard mode == .turn else {
            if bargeIn.observe(level: level, at: instant) {
                let callback = interrupted
                stop()
                callback?()
            }
            return
        }
        partial(transcript, level)
        switch detector.observe(level: level, at: instant) {
        case .endOfTurn: finish()
        case .heardNothing: finish(failure: Failure.noSpeech)
        case .tooLong: transcript.isEmpty ? finish(failure: Failure.tooLong) : finish()
        case .waiting, .hearing: break
        }
    }

    private func received(
        text: String?,
        final: Bool,
        failed: Bool,
        id: UUID,
        partial: @escaping @MainActor (String, Double) -> Void
    ) {
        guard recordingID == id else { return }
        if let text, !text.isEmpty {
            transcript = text
            partial(text, 0)
        }
        if final {
            finish()
        } else if failed, transcript.isEmpty {
            finish(failure: Failure.recognitionUnavailable)
        } else if failed {
            finish()
        }
    }

    func finish(failure: (any Error)? = nil) {
        let callback = completion
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        if let failure {
            callback?(.failure(failure))
        } else if text.isEmpty {
            callback?(.failure(Failure.noSpeech))
        } else {
            callback?(.success(text))
        }
    }

    func stop() {
        recordingID = nil
        completion = nil
        interrupted = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }
}
