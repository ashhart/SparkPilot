import SwiftUI

@MainActor
struct SparkAudioSettingsView: View {
    @State private var session: SparkVoiceSession
    init(chat: SparkChatModel, initialTarget: SparkVoiceTarget? = nil) {
        _session = State(
            initialValue: SparkVoiceSession(
                chat: chat,
                dictationOnly: false,
                warmsFillers: false,
                initialTarget: initialTarget
            )
        )
    }
    var body: some View {
        SparkAudioSettingsForm(session: session)
            .navigationTitle("Audio")
            .task { await session.prepare() }
            .onDisappear { session.stop() }
    }
}

@MainActor
struct SparkAudioSettingsForm: View {
    @Bindable var session: SparkVoiceSession
    @AppStorage(SparkVoiceOutputPreference.key) private var output = SparkVoiceOutputPreference
        .spark.rawValue
    @AppStorage(SparkVoiceRecognitionPolicy.allowsAppleServersKey) private var allowsAppleSpeech =
        false

    var body: some View {
        Form {
            Section {
                Picker("Spoken replies", selection: $output) {
                    ForEach(SparkVoiceOutputPreference.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                .accessibilityIdentifier("spark.audio.output")
                if output == SparkVoiceOutputPreference.device.rawValue {
                    LabeledContent("Voice", value: SparkVoiceDeviceSpeaker.voiceName)
                    Text("Replies are read using a voice installed on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Picker(
                        "Voice",
                        selection: Binding(get: { session.voice }, set: { session.choose($0) })
                    ) {
                        ForEach(SparkKokoroVoice.allCases) { voice in
                            Text(voice.name).tag(voice).disabled(!session.isVoiceAvailable(voice))
                        }
                    }
                    if session.installed {
                        Button("Play a sample", systemImage: "play.fill") {
                            session.preview(session.voice)
                        }
                    }
                }
            } header: {
                Text("Playback")
            }
            Section {
                Toggle(
                    SparkVoicePermissionPresentation.appleServiceSettingTitle,
                    isOn: $allowsAppleSpeech
                )
                .accessibilityIdentifier("spark.audio.apple-speech")
            } header: {
                Text("Dictation")
            } footer: {
                Text(
                    SparkVoicePermissionPresentation.recognitionPromise(
                        allowsAppleServers: allowsAppleSpeech
                    )
                )
            }
            Section("Kokoro on your Spark") {
                if session.targets.count > 1 {
                    Picker(
                        "Spark",
                        selection: Binding(
                            get: { session.target?.id },
                            set: { id in
                                if let target = session.targets.first(where: { $0.id == id }) {
                                    session.chooseTarget(target)
                                }
                            }
                        )
                    ) {
                        ForEach(session.targets) { target in
                            Text(target.displayName).tag(Optional(target.id))
                        }
                    }
                    .disabled(session.phase == .downloading)
                } else if let target = session.target {
                    Text(target.displayName)
                }
                serviceControls
                if let error = session.error { Text(error).foregroundStyle(.secondary) }
                if session.phase == .downloading {
                    if let fraction = session.operationProgress {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Text("You can close this screen; the operation continues on the Spark.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: output) { _, _ in session.refreshVoicePreference() }
    }

    @ViewBuilder private var serviceControls: some View {
        if session.phase == .checking {
            ProgressView()
        } else if session.target == nil {
            Text(
                SparkVoiceAvailabilityCopy.message(for: session.voiceUnavailable ?? .noSparkPaired)
            )
            .foregroundStyle(.secondary)
        } else {
            if session.serviceStatus?.installed == true {
                Toggle(
                    "Kokoro voice",
                    isOn: Binding(
                        get: { session.serviceStatus?.running == true },
                        set: { session.change($0 ? .enable : .disable) }
                    )
                )
                .disabled(session.phase == .downloading)
            } else {
                Button("Install Kokoro on Spark", systemImage: "arrow.down.circle") {
                    session.download()
                }
                .disabled(session.phase == .downloading)
            }
            if session.serviceStatus?.updateAvailable == true {
                Button("Update Kokoro", systemImage: "arrow.down.circle") {
                    session.change(.update)
                }
                .disabled(session.phase == .downloading)
            }
            Button("Check for updates", systemImage: "arrow.clockwise") { session.checkUpdates() }
                .disabled(session.phase == .downloading)
            if session.updateChecked, session.serviceStatus?.updateAvailable == false,
                session.serviceStatus?.installed == true
            {
                Text("Kokoro is up to date for this Spark Runtime.").font(.footnote)
            }
        }
    }
}
