import AVFoundation
import Combine
import SwiftUI

enum SparkVoiceMode: Equatable, Identifiable {
    case dictation, conversation, setup
    case readAloud(String)
    var id: String {
        switch self {
        case .dictation: "dictation"
        case .conversation: "conversation"
        case .setup: "setup"
        case .readAloud: "readAloud"
        }
    }

    /// Setup synthesises the pool too, so the first spoken turn already has a filler on disk.
    var warmsFillers: Bool { self == .conversation || self == .setup }

    var readsAloud: Bool { if case .readAloud = self { true } else { false } }
}

@MainActor
struct SparkVoiceChatView: View {
    @State private var session: SparkVoiceSession
    @State private var showsAudioSettings = false
    @State private var showsOutputChoice = false
    @State private var startedReading = false
    @State var allowsAppleSpeech = SparkVoiceRecognitionPolicy.allowsAppleServers()
    let mode: SparkVoiceMode
    private let installOnOpen: Bool
    private var isPreview = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    init(
        model: SparkChatModel,
        mode: SparkVoiceMode,
        initialTarget: SparkVoiceTarget? = nil,
        installOnOpen: Bool = false
    ) {
        self.installOnOpen = installOnOpen
        self.mode = mode
        _session = State(
            initialValue: SparkVoiceSession(
                chat: model,
                dictationOnly: mode == .dictation,
                conversation: mode == .conversation,
                readsAloud: mode.readsAloud,
                warmsFillers: mode.warmsFillers,
                initialTarget: initialTarget
            )
        )
    }

    #if DEBUG
        init(previewSession: SparkVoiceSession) {
            mode = .conversation
            installOnOpen = false
            isPreview = true
            _session = State(initialValue: previewSession)
        }
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if mode == .setup {
                    SparkAudioSettingsForm(session: session)
                } else {
                    GeometryReader { geometry in
                        ScrollView {
                            VStack(spacing: 24) {
                                waveform(session)
                                    .frame(height: min(160, geometry.size.height * 0.25))
                                    .accessibilityHidden(true)
                                headline
                                if showsOutputChoice { outputChoice }
                                if session.phase == .downloading { progress }
                                if !session.dictationOnly { targetAndVoice }
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height, alignment: .center)
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 16) {
                            if !showsOutputChoice { action(session).controlSize(.large) }
                            Button("Back to chat", systemImage: "text.bubble") {
                                session.stop()
                                dismiss()
                            }
                            .frame(minHeight: 44)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(20)
                        .background(ChatStyle.canvas)
                        .accessibilityIdentifier("spark.voice.controls")
                    }
                }
            }
            .background(ChatStyle.canvas)
            .safeAreaInset(edge: .top) {
                if isPreview {
                    Text("Preview · microphone is off").font(.caption).padding(8)
                        .frame(maxWidth: .infinity).background(ChatStyle.canvas)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        session.stop()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Close voice")
                }
            }
            .toolbar {
                if mode != .setup {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            session.stop()
                            showsAudioSettings = true
                        } label: {
                            Image(systemName: "slider.horizontal.3").frame(
                                minWidth: 44,
                                minHeight: 44
                            )
                        }
                        .accessibilityLabel("Audio settings")
                    }
                }
            }
            #if os(iOS)
                .toolbarBackground(ChatStyle.canvas, for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            #endif
            .sheet(
                isPresented: $showsAudioSettings,
                onDismiss: {
                    allowsAppleSpeech = SparkVoiceRecognitionPolicy.allowsAppleServers()
                    session.refreshVoicePreference()
                    session.work = Task { await session.prepare() }
                }
            ) {
                NavigationStack {
                    SparkAudioSettingsView(chat: session.chat, initialTarget: session.target)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showsAudioSettings = false }
                            }
                        }
                }
                .presentationBackground(ChatStyle.canvas)
            }
        }
        .presentationBackground(ChatStyle.canvas)
        #if os(macOS)
            .frame(minWidth: 460, idealWidth: 540, minHeight: 620)
        #endif
        .task {
            guard !isPreview else { return }
            SparkVoiceCoordinator.shared.claim(session, as: .phone)
            await session.prepare()
            guard SparkVoiceCoordinator.shared.holds(session), !Task.isCancelled else { return }
            if installOnOpen, session.serviceStatus?.installed == false,
                session.phase == .needsDownload
            {
                session.download()
            }
            if session.needsOutputChoice {
                showsOutputChoice = true
                return
            }
            startReadingIfReady()
        }
        .onChange(of: session.output) { _, _ in
            guard !showsOutputChoice else { return }
            startReadingIfReady()
        }
        .onDisappear {
            if SparkVoiceCoordinator.shared.holds(session) {
                session.stop()
                SparkVoiceCoordinator.shared.release(session)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, SparkVoiceCoordinator.shared.holds(session) { session.stop() }
        }
        .onChange(of: session.didDictate) { _, finished in if finished { dismiss() } }
    }

    @ViewBuilder private var headline: some View {
        VStack(spacing: 10) {
            Text(status).font(.title2.weight(.semibold))
            if session.phase == .permissionNeeded {
                permissionNotice(session, openURL: openURL)
            } else if let reason = session.voiceUnavailable, session.output == .device,
                session.outputPreference == .spark
            {
                Text(SparkVoiceAvailabilityCopy.message(for: reason))
                    .font(.callout).foregroundStyle(.secondary)
                Text(SparkVoiceAvailabilityCopy.deviceFallback)
                    .font(.callout).foregroundStyle(.secondary)
            } else if let error = session.error {
                Text(error).font(.callout).foregroundStyle(.secondary)
            } else if let filler = session.fillerPhrase {
                Text(filler).font(.title3).foregroundStyle(.secondary)
            } else if !session.transcript.isEmpty {
                Text(session.transcript).font(.title3).foregroundStyle(.secondary)
            } else {
                Text(explanation).font(.callout).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)
    }

    /// The first read-aloud without Kokoro: one choice, Kokoro recommended, nothing to hunt for in Settings.
    @ViewBuilder private var outputChoice: some View {
        VStack(spacing: 14) {
            Text("Which voice should read replies?").font(.headline)
            Text(
                "Kokoro runs on your Spark with natural voices. It downloads once, about 3 GB with the voices included, then works without the internet. Apple's voice on this device works right away."
            )
            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button {
                showsOutputChoice = false
                session.chooseOutput(.spark)
                session.download()
            } label: {
                Label(
                    "Install Kokoro on Spark (recommended)",
                    systemImage: "arrow.down.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .controlSize(.large)
            .disabled(session.target == nil)
            .accessibilityIdentifier("spark.voice.choice.kokoro")
            Button {
                showsOutputChoice = false
                session.chooseOutput(.device)
                startReadingIfReady()
            } label: {
                Label("Use Apple's voice on this device", systemImage: "iphone")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("spark.voice.choice.device")
            Text("You can change this later in Audio settings.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder private var progress: some View {
        VStack(spacing: 6) {
            if let fraction = session.operationProgress {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            if let line = SparkVoiceInstallPresentation.line(
                stage: session.operationStage,
                fraction: session.operationProgress
            ) {
                Text(line).font(.footnote).foregroundStyle(.secondary)
            }
            if let startedAt = session.operationStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = Duration.seconds(
                        max(0, Int(context.date.timeIntervalSince(startedAt)))
                    )
                    Text(
                        .operationElapsed(clock: elapsed.formatted(.time(pattern: .minuteSecond)))
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let hint = SparkVoiceInstallPresentation.hint(stage: session.operationStage) {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Installing Kokoro on Spark")
        .frame(maxWidth: 320)
    }

    @ViewBuilder private var targetAndVoice: some View {
        if let target = session.target {
            Label(target.displayName, systemImage: "desktopcomputer")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        Label(session.speakingVoiceName, systemImage: "waveform")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private func startReadingIfReady() {
        guard !startedReading, session.output != .silent, case .readAloud(let content) = mode
        else { return }
        startedReading = true
        session.readAloud(content)
    }

    private var title: String {
        switch mode {
        case .dictation: String(localized: "Dictate a message")
        case .conversation: String(localized: "Voice chat")
        case .readAloud: String(localized: "Read aloud")
        case .setup: String(localized: "Set up voice")
        }
    }

    private var status: String {
        switch session.phase {
        case .checking: String(localized: "Getting ready")
        case .permissionNeeded:
            SparkVoicePermissionPresentation.notice(for: session.permission)?.title
                ?? String(localized: "Voice paused")
        case .needsDownload:
            session.serviceStatus?.installed == true
                ? String(localized: "Voice is off") : String(localized: "Meet your voice")
        case .downloading:
            switch session.serviceAction {
            case .disable: String(localized: "Turning voice off")
            case .enable: String(localized: "Starting voice")
            case .update: String(localized: "Updating Kokoro")
            default: String(localized: "Installing on your Spark")
            }
        case .ready: String(localized: "Ready when you are")
        case .listening: String(localized: "Listening…")
        case .heardYou: String(localized: "Heard you")
        case .thinking: String(localized: "Thinking")
        case .speaking: String(localized: "Speaking")
        case .failed: String(localized: "Voice paused")
        }
    }

    private var explanation: String {
        if session.dictationOnly {
            return String(localized: "Speak your message, then review it before sending.")
        }
        if session.outputPreference == .device, session.output == .device {
            return String(
                localized: "Replies use this device’s voice; your Spark provides the answers."
            )
        }
        if session.serviceStatus?.installed == true, session.serviceStatus?.running == false {
            return String(
                localized:
                    "Your voices stay installed on the Spark. Turn Kokoro back on whenever you want, without downloading it again."
            )
        }
        if !session.installed {
            return String(
                localized:
                    "Install Kokoro on your Spark once, then choose a voice for spoken replies. No Hugging Face account needed."
            )
        }
        if case .readAloud = mode {
            return String(localized: "Listen to this reply in your chosen voice.")
        }
        if mode == .setup {
            return String(
                localized:
                    "Your voices are ready. Use the microphone to dictate, the waveform to talk, or the speaker below any reply to listen."
            )
        }
        return String(
            localized:
                "Speak, then pause. Your Spark answers and speaks, then listens again. The microphone is used only while you are talking to your Spark."
        )
    }
}
