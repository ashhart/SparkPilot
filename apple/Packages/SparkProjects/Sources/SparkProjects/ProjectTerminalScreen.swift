import SwiftUI
@preconcurrency import SwiftTerm

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Keep the emulator alive when SwiftUI switches panels; never replay escape sequences on redraw.
@MainActor
final class ProjectTerminalScreen: NSObject, @preconcurrency TerminalViewDelegate {
    let view = TerminalView(frame: .zero)
    var onInput: ((String) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    private(set) var colorScheme: ColorScheme?
    var columns: Int { view.getTerminal().cols }
    var rows: Int { view.getTerminal().rows }

    override init() {
        super.init()
        view.terminalDelegate = self
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        applyAppearance(.light)
        #if !os(macOS)
            view.accessibilityLabel = String(localized: "Development terminal")
            view.inputAccessoryView = nil
        #endif
    }

    func applyAppearance(_ scheme: ColorScheme) {
        guard colorScheme != scheme else { return }
        colorScheme = scheme
        let background = scheme == .dark ? SwiftUI.Color.black : SwiftUI.Color.white
        let foreground = scheme == .dark ? SwiftUI.Color.white : SwiftUI.Color.black
        #if os(macOS)
            view.nativeBackgroundColor = NSColor(background)
            view.nativeForegroundColor = NSColor(foreground)
            view.caretColor = NSColor(foreground)
            view.selectedTextForegroundColor = NSColor(foreground)
            view.selectedTextBackgroundColor = NSColor(SwiftUI.Color.accentColor.opacity(0.22))
        #else
            view.nativeBackgroundColor = UIColor(background)
            view.nativeForegroundColor = UIColor(foreground)
            view.caretColor = UIColor(foreground)
            view.selectedTextForegroundColor = UIColor(foreground)
            view.selectedTextBackgroundColor = UIColor(SwiftUI.Color.accentColor.opacity(0.22))
            view.keyboardAppearance = scheme == .dark ? .dark : .light
            if view.isFirstResponder { view.reloadInputViews() }
        #endif
        // Adapt default text and background only; preserve the harness's ANSI palette.
    }

    func reset() { view.getTerminal().resetToInitialState() }
    func feed(_ text: String) { view.feed(byteArray: Array(text.utf8)[...]) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize?(newCols, newRows)
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(String(decoding: data, as: UTF8.self))
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    // A remote process must not read/write the device clipboard or open arbitrary app URLs.
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // This delegate is invoked by a user's tap, never merely by an OSC hyperlink arriving.
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
            ["https", "http"].contains(scheme),
            url.host != nil, url.user == nil, url.password == nil
        else { return }
        #if os(macOS)
            NSWorkspace.shared.open(url)
        #else
            UIApplication.shared.open(url)
        #endif
    }
}

#if os(macOS)
    struct ProjectTerminalCanvas: NSViewRepresentable {
        let screen: ProjectTerminalScreen
        @Environment(\.colorScheme) private var colorScheme
        func makeNSView(context: Context) -> TerminalView {
            screen.applyAppearance(colorScheme)
            return screen.view
        }
        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: TerminalView,
            context: Context
        ) -> CGSize? {
            proposal.replacingUnspecifiedDimensions()
        }
        func updateNSView(_ view: TerminalView, context: Context) {
            screen.applyAppearance(colorScheme)
        }
    }
#else
    struct ProjectTerminalCanvas: UIViewRepresentable {
        let screen: ProjectTerminalScreen
        @Environment(\.colorScheme) private var colorScheme
        func makeUIView(context: Context) -> TerminalView {
            screen.applyAppearance(colorScheme)
            return screen.view
        }
        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: TerminalView,
            context: Context
        ) -> CGSize? {
            // A previous full-screen grid must not become the minimum width of a split pane.
            proposal.replacingUnspecifiedDimensions()
        }
        func updateUIView(_ view: TerminalView, context: Context) {
            screen.applyAppearance(colorScheme)
        }
    }
#endif
