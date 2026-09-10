import SwiftUI

/// The controls on the voice screen. Every one carries a label and a symbol in both appearances.
extension SparkVoiceChatView {
    @ViewBuilder func waveform(_ session: SparkVoiceSession) -> some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 24,
                paused: session.phase != .speaking || reduceMotion
            )
        ) { context in
            HStack(spacing: 8) {
                ForEach(0..<7) { index in
                    Capsule()
                        .fill(Color.primary.opacity(barOpacity(session)))
                        .frame(
                            width: 13,
                            height: barHeight(session, index, at: context.date)
                        )
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: session.level)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: session.phase)
        }
    }

    private func barOpacity(_ session: SparkVoiceSession) -> Double {
        switch session.phase {
        case .listening: 0.45 + 0.55 * min(1, session.level * 1.6)
        case .speaking: 1
        case .thinking, .heardYou: 0.6
        default: 0.22
        }
    }

    private func barHeight(_ session: SparkVoiceSession, _ index: Int, at date: Date) -> CGFloat {
        let shape = [0.3, 0.65, 0.85, 1.0, 0.85, 0.65, 0.3][index]
        if session.phase == .listening { return 18 + 100 * shape * session.level }
        if session.phase == .speaking {
            guard !reduceMotion else { return 20 + 24 * shape }
            let time = date.timeIntervalSinceReferenceDate
            let pulse = (sin(time * 6.4 + Double(index) * 0.9) + 1) / 2
            let swell = (sin(time * 2.3 + Double(index) * 0.35) + 1) / 2
            return 18 + 76 * shape * (0.2 + 0.8 * pulse * swell)
        }
        if session.phase == .thinking || session.phase == .heardYou { return 18 + 34 * shape }
        return 16 + 24 * shape
    }

    @ViewBuilder func permissionNotice(_ session: SparkVoiceSession, openURL: OpenURLAction)
        -> some View
    {
        let notice = SparkVoicePermissionPresentation.notice(
            for: session.permission,
            allowsAppleServers: allowsAppleSpeech
        )
        if let notice {
            VStack(spacing: 12) {
                Text(notice.message).font(.callout).foregroundStyle(.secondary)
                if let title = notice.actionTitle {
                    Button(title, systemImage: notice.opensSettings ? "gear" : "mic.fill") {
                        guard notice.opensSettings else {
                            session.requestPermission()
                            return
                        }
                        if let url = SparkVoicePermissionPresentation.settingsURL { openURL(url) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                }
            }
        }
    }

    @ViewBuilder func action(_ session: SparkVoiceSession) -> some View {
        switch session.phase {
        case .checking:
            ProgressView()
        case .permissionNeeded:
            EmptyView()
        case .needsDownload:
            installButton(session)
        case .downloading:
            Text("You can close this screen; the operation continues on the Spark.").font(.footnote)
                .foregroundStyle(.secondary)
        case .listening:
            Button {
                session.finishListening()
            } label: {
                Label(
                    session.dictationOnly
                        ? String(localized: "Finish dictation") : String(localized: "Send now"),
                    systemImage: "arrow.up"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
        case .heardYou, .thinking, .speaking:
            replyControls(session)
        case .ready, .failed:
            readyControls(session)
        }
    }

    @ViewBuilder private func replyControls(_ session: SparkVoiceSession) -> some View {
        if session.conversation {
            VStack(spacing: 12) {
                Button {
                    session.listen()
                } label: {
                    Label("Interrupt and talk", systemImage: "mic.fill")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                Button("Pause", systemImage: "pause.fill") { session.stop() }
                    .buttonStyle(.bordered)
                if session.isBargeInArmed {
                    Text("You can also just start talking.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else {
            Button("Stop playback", systemImage: "stop.fill") { session.stop() }
                .buttonStyle(.bordered)
                .tint(Color.accentColor)
        }
    }

    @ViewBuilder private func readyControls(_ session: SparkVoiceSession) -> some View {
        switch mode {
        case .readAloud(let content):
            if session.output == .silent {
                installButton(session)
            } else {
                readAloudControls(session, content: content)
            }
        case .setup:
            if session.installed {
                Button("Play a sample", systemImage: "play.fill") { session.preview(session.voice) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
            } else {
                installButton(session)
            }
        case .dictation, .conversation:
            if session.output != .silent || session.dictationOnly {
                Button {
                    session.listen()
                } label: {
                    Label(
                        session.dictationOnly
                            ? String(localized: "Start dictating")
                            : String(localized: "Start talking"),
                        systemImage: "mic.fill"
                    )
                    .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .accessibilityHint("Listens until you pause, then sends what you said")
            } else {
                installButton(session)
            }
        }
        if session.output == .kokoro, session.warmsFillers, session.installed, !session.fillersReady
        {
            Text("Preparing the voice so replies start straight away…")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Read the reply with whatever can speak, and still offer the Spark's own voice when it can.
    @ViewBuilder private func readAloudControls(_ session: SparkVoiceSession, content: String)
        -> some View
    {
        VStack(spacing: 12) {
            Button("Read aloud", systemImage: "speaker.wave.2.fill") { session.readAloud(content) }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
        }
    }

    @ViewBuilder private func installButton(_ session: SparkVoiceSession) -> some View {
        Button(
            session.serviceStatus?.installed == true
                ? String(localized: "Start voice") : String(localized: "Install Kokoro on Spark"),
            systemImage: "arrow.down.circle.fill"
        ) { session.download() }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        .disabled(session.target == nil)
    }

}
