import Foundation
import Observation
import SparkAPI

enum SparkKokoroVoice: String, CaseIterable, Identifiable {
    case heart = "af_heart"
    case bella = "af_bella"
    case sarah = "af_sarah"
    case kore = "af_kore"
    case fenrir = "am_fenrir"
    case puck = "am_puck"
    case fable = "bm_fable"
    case adam = "am_adam"
    case michael = "am_michael"
    case emma = "bf_emma"
    case george = "bm_george"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .heart: String(localized: "Heart")
        case .bella: String(localized: "Bella")
        case .sarah: String(localized: "Sarah")
        case .kore: String(localized: "Kore")
        case .fenrir: String(localized: "Fenrir")
        case .puck: String(localized: "Puck")
        case .fable: String(localized: "Fable")
        case .adam: String(localized: "Adam")
        case .michael: String(localized: "Michael")
        case .emma: String(localized: "Emma")
        case .george: String(localized: "George")
        }
    }

    var isMale: Bool {
        switch self {
        case .fenrir, .puck, .fable, .adam, .michael, .george: true
        default: false
        }
    }

    var detail: String {
        switch self {
        case .emma, .george, .fable: String(localized: "British English")
        default: String(localized: "American English")
        }
    }
}

/// Where a spoken request goes once it has been heard.
enum SparkVoiceRoute: Equatable, Sendable {
    /// The usual path: the request becomes a chat message and the reply is spoken.
    case chat
    /// Someone else answered it; the session waits for them to speak or listen again.
    case handled
}

@MainActor @Observable
final class SparkVoiceSession {
    enum Phase {
        case checking, needsDownload, downloading, ready, listening, heardYou, thinking, speaking
        case failed, permissionNeeded
    }
    // The turn, filler and barge-in half of this type lives in SparkVoiceTurn.swift.
    private(set) var outputPreference: SparkVoiceOutputPreference
    var phase = Phase.checking
    var transcript = ""
    var level = 0.0
    var error: String?
    var didDictate = false
    var permission = SparkVoicePermission.granted
    var fillerPhrase: String?
    var isBargeInArmed = false
    /// Why the Spark's Kokoro voice is not the one speaking, kept across the stops between turns.
    private(set) var voiceUnavailable: SparkVoiceAvailability?
    private(set) var voice =
        SparkKokoroVoice(
            rawValue: UserDefaults.standard.string(forKey: "spark.chat.kokoroVoice") ?? "af_heart"
        ) ?? .heart
    private(set) var installed = false
    var previewingVoice: SparkKokoroVoice?
    private(set) var serviceStatus: KokoroServiceStatus?
    private(set) var target: SparkVoiceTarget?
    private(set) var targets: [SparkVoiceTarget] = []
    private(set) var operationProgress: Double?
    private(set) var operationStage: String?
    /// When the current Kokoro operation was accepted, for an elapsed clock while the Spark reports no percentage.
    private(set) var operationStartedAt: Date?
    private(set) var updateChecked = false
    private(set) var serviceAction: KokoroServiceAction?
    private(set) var fillersReady = false
    let dictationOnly: Bool
    let conversation: Bool
    /// Read aloud is the one screen that can speak without a Spark, so it is the one that falls back.
    let readsAloud: Bool
    let warmsFillers: Bool
    let chat: SparkChatModel
    let capture: SparkVoiceCapture
    let player = SparkVoicePlayer()
    let service = SparkVoiceService()
    let fillers: SparkVoiceFillerCache
    private let initialTarget: SparkVoiceTarget?
    var work: Task<Void, Never>?
    var fillerWork: Task<Void, Never>?
    var fillerStarted = false
    var operation = UUID()
    var ownsChatRequest = false
    var externalRequests = false
    @ObservationIgnored var voiceTargetFilter: (SparkVoiceTarget) -> Bool = { _ in true }
    @ObservationIgnored var canUseAudio: () -> Bool = { true }
    var preparation: Task<Void, Never>?
    /// Set while a call holds the audio, so only a turn that was taken away is started again.
    var wasInterrupted = false
    @ObservationIgnored var deviceSpeechAvailable: () -> Bool = {
        SparkVoiceDeviceSpeaker.isAvailable
    }
    @ObservationIgnored var deviceSpeechOverride: ((String) async throws -> Void)?
    @ObservationIgnored lazy var deviceSpeaker = SparkVoiceDeviceSpeaker()
    /// A car or another surface can take a spoken request before it becomes a chat message.
    @ObservationIgnored var spokenRequestRouter: (@MainActor (String) -> SparkVoiceRoute)?
    /// After reading something aloud, open the microphone again instead of resting.
    @ObservationIgnored var resumesListeningAfterReadAloud = false

    init(
        chat: SparkChatModel,
        dictationOnly: Bool,
        conversation: Bool = false,
        readsAloud: Bool = false,
        warmsFillers: Bool? = nil,
        initialTarget: SparkVoiceTarget? = nil,
        capture: SparkVoiceCapture = SparkVoiceCapture(),
        fillers: SparkVoiceFillerCache = SparkVoiceFillerCache(),
        outputPreference: SparkVoiceOutputPreference = .saved()
    ) {
        self.outputPreference = outputPreference
        self.initialTarget = initialTarget
        self.target = initialTarget
        self.chat = chat
        self.dictationOnly = dictationOnly
        self.conversation = conversation
        self.readsAloud = readsAloud
        self.warmsFillers = warmsFillers ?? conversation
        self.capture = capture
        self.fillers = fillers
    }

    /// Only a screen that opens the microphone is held up by the permission to open it.
    static func listens(dictationOnly: Bool, conversation: Bool) -> Bool {
        dictationOnly || conversation
    }

    /// The phase a screen waits in; an unanswered microphone is asked about before "ready".
    static func restingPhase(
        permission: SparkVoicePermission,
        listens: Bool,
        installed: Bool,
        dictationOnly: Bool
    ) -> Phase {
        if listens, permission != .granted { return .permissionNeeded }
        return installed || dictationOnly ? .ready : .needsDownload
    }

    private var restingPhase: Phase {
        // A device that can speak is a voice that is installed, so the screen rests on ready.
        Self.restingPhase(
            permission: permission,
            listens: Self.listens(dictationOnly: dictationOnly, conversation: conversation),
            installed: installed || output == .device,
            dictationOnly: dictationOnly
        )
    }

    /// Kokoro when the Spark can speak; otherwise this device, so text already here is read.
    static func output(
        installed: Bool,
        hasTarget: Bool,
        deviceSpeechAvailable: Bool,
        preference: SparkVoiceOutputPreference = .spark
    )
        -> SparkVoiceOutput
    {
        if preference == .device { return deviceSpeechAvailable ? .device : .silent }
        if installed, hasTarget { return .kokoro }
        return deviceSpeechAvailable ? .device : .silent
    }

    /// A Spark that is paired but silent is a different problem from having none.
    static func unavailability(pairedTargetCount: Int) -> SparkVoiceAvailability {
        pairedTargetCount > 0 ? .sparkUnreachable : .noSparkPaired
    }

    /// The owner's §39.2 policy comes before any surface's filter: on-device-only has no Spark.
    func permits(_ target: SparkVoiceTarget) -> Bool {
        chat.executionPolicy?.choice != .onDeviceOnly && voiceTargetFilter(target)
    }

    var output: SparkVoiceOutput {
        Self.output(
            installed: installed,
            hasTarget: target.map(permits) ?? false,
            deviceSpeechAvailable: (readsAloud
                || (conversation && target != nil && outputPreference == .device))
                && deviceSpeechAvailable(),
            preference: outputPreference
        )
    }

    /// A first read-aloud on a Spark without Kokoro asks which voice should read replies, once.
    var needsOutputChoice: Bool {
        readsAloud && target != nil && voiceUnavailable == .kokoroMissing
            && !SparkVoiceOutputPreference.hasChosen()
    }

    /// Record the owner's answer and apply it at once.
    func chooseOutput(_ preference: SparkVoiceOutputPreference) {
        SparkVoiceOutputPreference.choose(preference)
        refreshVoicePreference()
    }

    func refreshVoicePreference() {
        stop()
        outputPreference = .saved()
        voice =
            SparkKokoroVoice(
                rawValue: UserDefaults.standard.string(forKey: "spark.chat.kokoroVoice")
                    ?? "af_heart"
            ) ?? .heart
        phase = restingPhase
    }

    func speakOnDevice(_ text: String) async throws {
        if let deviceSpeechOverride {
            try await deviceSpeechOverride(text)
        } else {
            try await deviceSpeaker.speak(text)
        }
    }

    /// The name of whichever voice will speak, so the screen never names the wrong one.
    var speakingVoiceName: String {
        output == .device ? SparkVoiceDeviceSpeaker.voiceName : voice.name
    }

    /// Say why the Spark is not speaking, and fall back rather than leaving the reply unread.
    private func unavailable(_ reason: SparkVoiceAvailability) {
        voiceUnavailable = reason
        guard readsAloud, deviceSpeechAvailable() else {
            fail(SparkVoiceAvailabilityCopy.message(for: reason))
            return
        }
        phase = .ready
    }

    func prepare() async {
        let id = operation
        let observedPermission = await SparkVoiceCapture.permission(requesting: false)
        guard operation == id, !Task.isCancelled else { return }
        permission = observedPermission
        if dictationOnly {
            phase = restingPhase
            return
        }
        targets = chat.voiceTargets.filter(permits)
        if let initialTarget, permits(initialTarget),
            !targets.contains(where: { $0.nodeID == initialTarget.nodeID })
        {
            targets.insert(initialTarget, at: 0)
        }
        target =
            targets.first(where: { $0.nodeID == target?.nodeID })
            ?? targets.first(where: { $0.id == chat.selectedTargetID }) ?? targets.first
        guard let target else {
            unavailable(
                chat.executionPolicy?.choice == .onDeviceOnly
                    ? .onDeviceOnlyPolicy
                    : Self.unavailability(pairedTargetCount: chat.catalogue.pairedTargetCount)
            )
            return
        }
        if outputPreference == .device, readsAloud || conversation, deviceSpeechAvailable() {
            voiceUnavailable = nil
            phase = restingPhase
            return
        }
        phase = .checking
        do {
            if let saved = UserDefaults.standard.string(forKey: receiptKey(target)),
                let operationID = UUID(uuidString: saved)
            {
                phase = .downloading
                try await follow(operationID, target: target, id: id)
            }
            let status = try await service.status(target)
            guard operation == id, !Task.isCancelled else { return }
            apply(status)
        } catch {
            guard operation == id, !Task.isCancelled else { return }
            fail(serviceError(error))
        }
    }

    private func apply(_ status: KokoroServiceStatus) {
        serviceStatus = status
        // A paired Spark may still run the earlier six-voice runtime.
        if !status.voices.contains(voice.rawValue),
            let supported = SparkKokoroVoice.allCases.first(where: {
                status.voices.contains($0.rawValue)
            })
        {
            voice = supported
        }
        installed = status.installed && status.healthy
        voiceUnavailable = installed ? nil : .kokoroMissing
        phase = restingPhase
        if installed { prepareFillers() }
        if status.installed && !status.healthy {
            error =
                status.running
                ? String(
                    localized:
                        "Kokoro is starting or needs attention. Check its status again in a moment."
                )
                : String(
                    localized: "Kokoro is turned off. Turn it on whenever you want spoken replies."
                )
        }
    }

    /// Synthesise the filler pool once per voice so a turn ending never waits on the network.
    func prepareFillers() {
        guard outputPreference == .spark, warmsFillers, installed, let target, !fillers.isPrepared
        else { return }
        let selected = voice
        preparation?.cancel()
        preparation = startWarmUp(voice: selected) { [service] text in
            try await service.speech(text, voice: selected, target: target)
        }
    }

    /// The warm-up itself, so a test can drive it without a Spark.
    @discardableResult
    func startWarmUp(
        voice selected: SparkKokoroVoice,
        synthesise: @escaping @MainActor (String) async throws -> Data
    ) -> Task<Void, Never> {
        let cache = fillers
        let task = Task { [weak self] in
            // The screen may be dismissed between two phrases, so the session is only ever borrowed.
            await cache.prepare(voice: selected) { [weak self] text in
                guard self != nil, !Task.isCancelled else { throw CancellationError() }
                return try await synthesise(text)
            }
            guard let self, !Task.isCancelled, voice == selected else { return }
            fillersReady = cache.isPrepared
        }
        preparation = task
        return task
    }

    /// A screen that goes away without calling stop still stops warming the pool.
    isolated deinit { preparation?.cancel() }

    /// What an interruption means for a screen in this state; the notification alone cannot say.
    static func response(
        to interruption: SparkVoiceInterruption,
        phase: Phase,
        conversation: Bool,
        wasInterrupted: Bool
    ) -> SparkVoiceInterruptionResponse {
        switch interruption {
        case .began:
            return holdsAudio(phase) ? .stop : .ignore
        case .ended(let resume):
            guard resume, conversation, wasInterrupted else { return .ignore }
            return .resume
        }
    }

    /// The phases that own the microphone or the speaker, which an interruption takes away.
    static func holdsAudio(_ phase: Phase) -> Bool {
        switch phase {
        case .listening, .heardYou, .thinking, .speaking: true
        default: false
        }
    }

    func chooseTarget(_ value: SparkVoiceTarget) {
        stop()
        installed = false
        serviceStatus = nil
        target = value
        work = Task { [weak self] in await self?.prepare() }
    }

    func checkUpdates() {
        stop()
        updateChecked = true
        work = Task { [weak self] in await self?.prepare() }
    }

    func download() { change(serviceStatus?.installed == true ? .enable : .install) }

    func change(_ action: KokoroServiceAction) {
        stop()
        guard let target else { return }
        let id = operation
        phase = .downloading
        serviceAction = action
        operationProgress = nil
        operationStage = nil
        operationStartedAt = Date()
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let keyName = receiptKey(target) + "." + action.rawValue
                let key =
                    UserDefaults.standard.string(forKey: keyName).flatMap(UUID.init(uuidString:))
                    ?? UUID()
                UserDefaults.standard.set(key.uuidString, forKey: keyName)
                let accepted = try await service.change(action, target: target, key: key)
                UserDefaults.standard.set(accepted.id.uuidString, forKey: receiptKey(target))
                UserDefaults.standard.removeObject(forKey: keyName)
                try await follow(accepted.id, target: target, id: id)
                let status = try await service.status(target)
                guard operation == id, !Task.isCancelled else { return }
                apply(status)
            } catch {
                guard operation == id, !Task.isCancelled else { return }
                fail(serviceError(error))
            }
        }
    }

    private func receiptKey(_ target: SparkVoiceTarget) -> String {
        "spark.kokoro.operation." + target.nodeID.rawValue.uuidString.lowercased()
    }

    private func follow(_ operationID: UUID, target: SparkVoiceTarget, id: UUID) async throws {
        for _ in 0..<1_200 {
            try Task.checkCancellation()
            guard operation == id else { throw CancellationError() }
            let result = try await service.operation(operationID, target: target)
            operationProgress = result.progress
            operationStage = result.stage
            switch result.state {
            case .succeeded:
                UserDefaults.standard.removeObject(forKey: receiptKey(target))
                return
            case .failed, .cancelled:
                UserDefaults.standard.removeObject(forKey: receiptKey(target))
                throw APIError(.reported, code: result.errorCode)
            default: try await Task.sleep(for: .seconds(2))
            }
        }
        throw URLError(.timedOut)
    }

    private func serviceError(_ error: any Error) -> String {
        if let api = error as? APIError, api.statusCode == 404 {
            return String(
                localized: "Update Spark Runtime in Settings to add Kokoro voice support."
            )
        }
        return String(
            localized:
                "The Spark voice service could not finish. Check its connection and retry; an accepted installation continues on the Spark."
        )
    }

    func choose(_ voice: SparkKokoroVoice) {
        guard isVoiceAvailable(voice) else { return }
        stop()
        self.voice = voice
        UserDefaults.standard.set(voice.rawValue, forKey: "spark.chat.kokoroVoice")
        fillers.invalidate()
        fillersReady = false
        prepareFillers()
    }

    func isVoiceAvailable(_ voice: SparkKokoroVoice) -> Bool {
        serviceStatus?.voices.contains(voice.rawValue) ?? true
    }

    static func spokenText(_ content: String) -> String {
        SparkChatMarkdown.blocks(in: content).compactMap { block -> String? in
            switch block {
            case .paragraph(let text), .heading(_, let text), .listItem(_, let text),
                .quote(let text):
                String(SparkChatMarkdown.inline(text).characters)
            case .code:
                String(localized: "There is a code example in the chat.")
            case .chart(.ready(let spec)):
                SparkChartAccessibility.summary(spec)
            case .chart:
                String(localized: "There is a chart in the chat that could not be drawn.")
            case .divider:
                nil
            }
        }.joined(separator: "\n")
    }

    /// Keep complete sentences together; Kokoro performs its own phoneme chunking.
    static func speechChunks(_ text: String) -> [String] {
        var result: [String] = []
        var buffer = ""
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) {
            sentence,
            _,
            _,
            _ in
            guard let sentence else { return }
            if buffer.utf8.count + sentence.utf8.count > 6_000, !buffer.isEmpty {
                result.append(buffer)
                buffer = ""
            }
            for word in sentence.split(whereSeparator: { $0.isWhitespace }) {
                for character in String(word) + " " {
                    if buffer.utf8.count + String(character).utf8.count > 6_000 {
                        result.append(buffer)
                        buffer = ""
                    }
                    buffer.append(character)
                }
            }
        }
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(buffer) }
        return result
    }

    func stop() {
        preparation?.cancel()
        preparation = nil
        operation = UUID()
        work?.cancel()
        work = nil
        fillerWork?.cancel()
        fillerWork = nil
        preparation?.cancel()
        preparation = nil
        fillerStarted = false
        fillerPhrase = nil
        isBargeInArmed = false
        capture.stop()
        player.stop()
        deviceSpeaker.stop()
        SparkVoiceAudioSession.deactivate()
        if ownsChatRequest {
            chat.cancel()
            ownsChatRequest = false
        }
        level = 0
        previewingVoice = nil
        error = nil
        phase = restingPhase
    }
}
