import Foundation
@preconcurrency import SwiftTerm

/// A bounded, passive emulator for spoken output. It never resizes the remote terminal or answers its queries.
@MainActor
public final class ProjectTerminalReadback: @preconcurrency TerminalDelegate {
    private lazy var terminal = Terminal(
        delegate: self,
        options: TerminalOptions(cols: 160, rows: 50, scrollback: 100)
    )
    private var baseline: [String] = []
    public init() {}

    public func feed(_ text: String) { terminal.feed(text: text) }
    public func markRead() { baseline = lines }
    public var latest: String { String(lines.suffix(12).joined(separator: "\n").suffix(1800)) }
    public var unread: String {
        let current = lines
        // TUI redraws replace existing cells, so compare rendered lines rather than accumulating escape-stripped frames.
        let old = Set(baseline)
        return String(
            current.filter { !old.contains($0) }.suffix(12).joined(separator: "\n").suffix(1800)
        )
    }
    private var lines: [String] {
        var sanitiser = ProjectTerminalSanitiser()
        return sanitiser.append(String(decoding: terminal.getBufferAsData(), as: UTF8.self))
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.unicodeScalars.contains { CharacterSet.letters.contains($0) } }
    }
    public func send(source: Terminal, data: ArraySlice<UInt8>) {}
    public func isProcessTrusted(source: Terminal) -> Bool { false }
}
