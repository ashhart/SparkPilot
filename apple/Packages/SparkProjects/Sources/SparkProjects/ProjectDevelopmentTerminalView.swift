import SwiftUI
import SparkAPI
#if os(iOS)
    import UIKit
    import SwiftTerm
#endif

/// A full terminal surface; window and tab owners control attachment lifetime explicitly.
public struct ProjectDevelopmentTerminalView: View {
    @Bindable private var model: ProjectsModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.colorScheme) private var colorScheme
    private var palette: ProjectDevelopmentPalette { .init(colorScheme) }
    @State private var control = false
    @State private var keyboardVisible = false
    private let dismissKeyboard: () -> Void
    private let focusAccessibleInput: (() -> Void)?
    private let onDictate: (() -> Void)?
    private let isListening: Bool
    private let onReturn: (() -> Void)?
    /// True while the owner is driving: the keyboard stays down and the canvas takes no taps.
    private let typingPaused: Bool

    public init(
        model: ProjectsModel,
        dismissKeyboard: @escaping () -> Void = {},
        focusAccessibleInput: (() -> Void)? = nil,
        onDictate: (() -> Void)? = nil,
        isListening: Bool = false,
        onReturn: (() -> Void)? = nil,
        typingPaused: Bool = false
    ) {
        self.model = model
        self.dismissKeyboard = dismissKeyboard
        self.focusAccessibleInput = focusAccessibleInput
        self.onDictate = onDictate
        self.isListening = isListening
        self.onReturn = onReturn
        self.typingPaused = typingPaused
    }

    public var body: some View {
        VStack(spacing: 0) {
            if voiceOver || model.terminalDisplayMode == .accessibleText {
                ScrollView {
                    Text(
                        model.terminalTranscript.isEmpty
                            ? "Waiting for output" : model.terminalTranscript
                    )
                    .font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .accessibilityLabel("Terminal output")
            } else {
                ProjectTerminalCanvas(screen: model.terminalSession.screen)
                    .allowsHitTesting(!typingPaused)
            }
            if case .failed(let message) = model.terminalState {
                Text(message).font(.caption).foregroundStyle(.orange).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 4) {
                key(String(localized: "Esc"), value: "\u{1b}")
                key(String(localized: "Tab"), value: "\t")
                Menu {
                    key(String(localized: "Interrupt (Ctrl-C)"), value: "\u{03}")
                    key(String(localized: "End input (Ctrl-D)"), value: "\u{04}")
                    Button("Control key", systemImage: "control") {
                        control.toggle()
                        #if os(iOS)
                            model.terminalSession.screen.view.controlModifier = control
                        #endif
                    }
                    Divider()
                    key(String(localized: "Left arrow"), value: "\u{1b}[D")
                    key(String(localized: "Down arrow"), value: "\u{1b}[B")
                    key(String(localized: "Up arrow"), value: "\u{1b}[A")
                    key(String(localized: "Right arrow"), value: "\u{1b}[C")
                } label: {
                    Image(systemName: control ? "control" : "ellipsis")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("More terminal keys")
                .accessibilityValue(control ? "Control on" : "Control off")
                Spacer(minLength: 0)
                if let onDictate {
                    Button(action: onDictate) {
                        Image(systemName: isListening ? "stop.circle.fill" : "mic")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(isListening ? "Finish dictation" : "Dictate message")
                }
                Button {
                    if let onReturn { onReturn() } else { model.sendTerminalKeys("\r") }
                } label: {
                    Image(systemName: "return").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Return")
                .accessibilityIdentifier("spark.terminal.return")
                #if os(iOS)
                    Button {
                        if keyboardVisible {
                            model.terminalSession.screen.view.resignFirstResponder()
                            dismissKeyboard()
                        } else if voiceOver || model.terminalDisplayMode == .accessibleText {
                            focusAccessibleInput?()
                        } else {
                            dismissKeyboard()
                            model.terminalSession.screen.view.becomeFirstResponder()
                        }
                    } label: {
                        Image(
                            systemName: keyboardVisible
                                ? "keyboard.chevron.compact.down" : "keyboard"
                        )
                        .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(keyboardVisible ? "Hide Keyboard" : "Show Keyboard")
                    .disabled(typingPaused)
                #endif
            }
            .buttonStyle(.borderless)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 8)
            .background(.primary.opacity(0.04))
            .disabled(model.terminalState != .loaded)
        }
        .background(palette.canvas)
        .tint(palette.accent)
        #if os(iOS)
            .onChange(of: typingPaused) { _, paused in
                if paused {
                    model.terminalSession.screen.view.resignFirstResponder()
                    dismissKeyboard()
                }
            }
            .onAppear { keyboardVisible = model.terminalSession.screen.view.isFirstResponder }
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)
            ) { _ in
                keyboardVisible = true
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            ) { _ in
                keyboardVisible = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalViewControlModifierReset))
            { notification in
                if let view = notification.object as? UIView,
                    view === model.terminalSession.screen.view
                {
                    control = false
                }
            }
        #endif
    }

    private func key(_ title: String, value: String, label: String? = nil) -> some View {
        Button(title) {
            model.sendTerminalKeys(value)
            control = false
            #if os(iOS)
                model.terminalSession.screen.view.controlModifier = false
            #endif
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(label ?? title)
    }
}

public struct ProjectDevelopmentFilesView: View {
    private let model: ProjectsModel
    @Environment(\.dismiss) private var dismiss
    public init(model: ProjectsModel) { self.model = model }
    public var body: some View {
        NavigationStack {
            ProjectFilesView(model: model)
                .navigationTitle("Workspace Files")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await model.refreshProjectContents() }
                        }
                    }
                }
        }
    }
}
