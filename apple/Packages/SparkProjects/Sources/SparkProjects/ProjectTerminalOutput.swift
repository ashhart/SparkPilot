import Foundation

/// Strip control sequences and reordering scalars from container output, across frames (§42.9).
public struct ProjectTerminalSanitiser: Sendable {
    /// Abandon an escape a container never terminates rather than buffering it for ever.
    static let maximumPendingScalars = 4096

    private enum Mode: Sendable {
        case text
        case escape
        case controlSequence
        case operatingSystemCommand
    }

    private var mode: Mode = .text
    private var pending = 0
    private var sawEscapeInsideCommand = false

    public init() {}

    /// Append one received chunk and return only the scalars that are safe to display.
    public mutating func append(_ chunk: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in chunk.unicodeScalars {
            switch mode {
            case .text:
                if scalar == Self.escape {
                    mode = .escape
                    pending = 0
                } else if Self.isDisplayable(scalar) {
                    output.append(scalar)
                }
            case .escape:
                pending += 1
                if scalar == "[" {
                    mode = .controlSequence
                } else if scalar == "]" {
                    mode = .operatingSystemCommand
                    sawEscapeInsideCommand = false
                } else {
                    mode = .text
                }
            case .controlSequence:
                pending += 1
                if Self.isControlSequenceFinal(scalar) || pending > Self.maximumPendingScalars {
                    mode = .text
                }
            case .operatingSystemCommand:
                pending += 1
                let terminated =
                    scalar == Self.bell || (sawEscapeInsideCommand && scalar == "\\")
                sawEscapeInsideCommand = scalar == Self.escape
                if terminated || pending > Self.maximumPendingScalars {
                    mode = .text
                }
            }
        }
        return String(output)
    }

    private static let escape = Unicode.Scalar(0x1B)
    private static let bell = Unicode.Scalar(0x07)

    /// A CSI ends at its first final byte; parameter and intermediate bytes come before it.
    private static func isControlSequenceFinal(_ scalar: Unicode.Scalar) -> Bool {
        (0x40...0x7E).contains(scalar.value)
    }

    /// Keep newline and tab, drop every other control and every reordering or hiding scalar.
    static func isDisplayable(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x0A || value == 0x09 { return true }
        if value < 0x20 || value == 0x7F { return false }
        if (0x80...0x9F).contains(value) { return false }
        if (0x200B...0x200F).contains(value) { return false }
        if (0x202A...0x202E).contains(value) { return false }
        if (0x2060...0x2064).contains(value) { return false }
        if (0x2066...0x2069).contains(value) { return false }
        if value == 0xFEFF { return false }
        return true
    }
}
