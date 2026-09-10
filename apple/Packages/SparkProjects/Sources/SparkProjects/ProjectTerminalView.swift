import SparkAPI
import SparkDesignSystem
import SwiftUI

struct ProjectTerminalView: View {
    @Bindable var model: ProjectsModel
    @State private var shell: ProjectTerminalShell = .login
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    terminalPickers
                    Spacer()
                    terminalAction
                }
                VStack(alignment: .leading, spacing: 10) {
                    terminalPickers
                    terminalAction
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            switch model.terminalState {
            case .idle:
                ContentUnavailableView(
                    "Terminal closed",
                    systemImage: "terminal",
                    description: Text(
                        "Open a fixed shell inside this project's isolated container."
                    )
                )
            case .loading:
                ProgressView(String(localized: "Opening terminal"))
            case .failed(let message):
                ProjectFailureView(message: message) { await model.startTerminal(shell: shell) }
            case .empty, .loaded:
                terminalOutput

                HStack {
                    TextField("Terminal input", text: $model.terminalInput)
                        .font(.body.monospaced())
                        .onSubmit { Task { await model.sendTerminalInput() } }
                    Button("Send", systemImage: "arrow.up.circle.fill") {
                        Task { await model.sendTerminalInput() }
                    }
                    .disabled(model.terminalInput.isEmpty)
                }
            }
        }
        .padding()
    }

    private var terminalPickers: some View {
        HStack {
            Picker("Shell", selection: $shell) {
                ForEach(ProjectTerminalShell.allCases, id: \.rawValue) { shell in
                    Text(shell.rawValue.capitalized).tag(shell)
                }
            }
            .frame(maxWidth: 220)
            Picker("Terminal display", selection: $model.terminalDisplayMode) {
                ForEach(ProjectTerminalDisplayMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .frame(maxWidth: 260)
        }
    }

    @ViewBuilder
    private var terminalAction: some View {
        if model.terminal == nil {
            Button("Open Terminal", systemImage: "terminal") {
                Task { await model.startTerminal(shell: shell) }
            }
            .disabled(!model.canUseTerminal)
        } else {
            Button("Close Terminal", systemImage: "xmark.circle") {
                Task { await model.stopTerminal() }
            }
        }
    }

    @ViewBuilder
    private var terminalOutput: some View {
        // Never leave a screen-reader user with the accessibility-hidden styled view (§51.1).
        if model.terminalDisplayMode == .accessibleText || voiceOverEnabled {
            ScrollView {
                Text(
                    model.terminalTranscript.isEmpty
                        ? String(localized: "No output yet") : model.terminalTranscript
                )
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .accessibilityLabel("Terminal output")
            .accessibilityHint(ProjectAccessibility.terminalTextAlternative)
        } else {
            ProjectTerminalCanvas(screen: model.terminalSession.screen)
                .clipShape(RoundedRectangle(cornerRadius: 12))

        }
    }
}

/// Turn a rendered size into a character grid using the monospaced metrics the transcript uses.
enum ProjectTerminalGrid {
    static let characterWidth: CGFloat = 8
    static let lineHeight: CGFloat = 18

    struct Size: Equatable, Hashable, Sendable {
        let columns: Int
        let rows: Int
    }

    static func size(of proxy: CGSize) -> Size {
        Size(
            columns: min(max(Int((proxy.width / characterWidth).rounded(.down)), 20), 500),
            rows: min(max(Int((proxy.height / lineHeight).rounded(.down)), 5), 250)
        )
    }
}
