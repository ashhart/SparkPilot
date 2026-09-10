import Foundation

/// Bound Markdown structure and render oversized responses as intact plain text.
enum SparkChatMarkdown {
    enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case code(language: String?, text: String)
        case listItem(marker: String, text: String)
        case quote(String)
        case divider
        case chart(SparkChatChartBlock)
    }

    private static let maximumStructuredBytes = 256 * 1024
    private static let maximumBlocks = 512
    private static let maximumInlineBytes = 64 * 1024

    private struct Fence {
        let marker: Character
        let count: Int
        let language: String?
    }

    static func blocks(in text: String) -> [Block] {
        guard !text.isEmpty else { return [] }
        guard text.utf8.count <= maximumStructuredBytes else { return [.paragraph(text)] }

        // Split on newline scalars so CRLF grapheme clustering cannot hide line feeds.
        let lines = text.components(separatedBy: "\n")
        var result: [Block] = []
        var paragraph: [String] = []
        var quotation: [String] = []
        var fence: Fence?
        var code = ""

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        func flushQuote() {
            guard !quotation.isEmpty else { return }
            result.append(.quote(quotation.joined(separator: "\n")))
            quotation.removeAll(keepingCapacity: true)
        }

        for (index, rawLine) in lines.enumerated() {
            // Preserve code-block line endings, including CRLF and the newline preceding a closing fence.
            let hasNewline = index < lines.count - 1
            let isCRLF = hasNewline && rawLine.hasSuffix("\r")
            let line = isCRLF ? String(rawLine.dropLast()) : rawLine
            let ending = hasNewline ? (isCRLF ? "\r\n" : "\n") : ""
            let markup = structuralLine(line)

            if let open = fence {
                if let markup, closesFence(markup, open: open) {
                    result.append(fenced(open, code: code, isClosed: true))
                    fence = nil
                    code = ""
                } else {
                    code.append(line)
                    code.append(ending)
                }
            } else if let markup, let open = openingFence(markup) {
                flushParagraph()
                flushQuote()
                fence = open
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushParagraph()
                flushQuote()
            } else if let markup, let heading = heading(markup) {
                flushParagraph()
                flushQuote()
                result.append(heading)
            } else if let markup, isDivider(markup) {
                flushParagraph()
                flushQuote()
                result.append(.divider)
            } else if let markup, let item = listItem(markup) {
                flushParagraph()
                flushQuote()
                result.append(item)
            } else if let markup, markup.first == ">" {
                flushParagraph()
                let remainder = markup.dropFirst()
                quotation.append(String(remainder.first == " " ? remainder.dropFirst() : remainder))
            } else {
                flushQuote()
                paragraph.append(line)
            }

            if result.count > maximumBlocks { return [.paragraph(text)] }
        }
        if let fence { result.append(fenced(fence, code: code, isClosed: false)) }
        flushParagraph()
        flushQuote()
        return result.count <= maximumBlocks ? result : [.paragraph(text)]
    }

    static func inline(_ text: String) -> AttributedString {
        guard text.utf8.count <= maximumInlineBytes else { return AttributedString(text) }
        var value =
            (try? AttributedString(
                markdown: text,
                options: .init(
                    allowsExtendedAttributes: false,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )) ?? AttributedString(text)

        // Render image syntax as its label without loading remote images, linking their URLs or importing HTML.
        let removals = value.runs.compactMap { run in
            let image = run.imageURL != nil
            let unsupportedLink =
                run.link.map {
                    !["https", "mailto"].contains($0.scheme?.lowercased() ?? "")
                } ?? false
            return image || unsupportedLink ? (run.range, image) : nil
        }
        for (range, image) in removals {
            value[range].link = nil
            if image { value[range].imageURL = nil }
        }
        return value
    }

    /// A chart fence is read as a chart; every other fence stays the code the model wrote.
    private static func fenced(_ fence: Fence, code: String, isClosed: Bool) -> Block {
        guard SparkChatChartFence.matches(fence.language) else {
            return .code(language: fence.language, text: code)
        }
        return .chart(SparkChatChartFence.read(code, isClosed: isClosed))
    }

    /// Recognise block markers after at most three leading spaces, preserving deeper indentation as literal content.
    private static func structuralLine(_ line: String) -> Substring? {
        let indentation = line.prefix(while: { $0 == " " }).count
        return indentation <= 3 ? line.dropFirst(indentation) : nil
    }

    private static func openingFence(_ line: Substring) -> Fence? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let count = line.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let info = line.dropFirst(count).trimmingCharacters(in: .whitespaces)
        guard marker != "`" || !info.contains("`") else { return nil }
        return Fence(
            marker: marker,
            count: count,
            language: info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        )
    }

    private static func closesFence(_ line: Substring, open: Fence) -> Bool {
        let count = line.prefix(while: { $0 == open.marker }).count
        return count >= open.count
            && line.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func heading(_ line: Substring) -> Block? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let remainder = line.dropFirst(level)
        guard remainder.isEmpty || remainder.first == " " || remainder.first == "\t" else {
            return nil
        }
        var text = remainder.trimmingCharacters(in: .whitespaces)
        let closing = text.reversed().prefix(while: { $0 == "#" }).count
        let beforeClosing = text.dropLast(closing)
        if closing > 0, beforeClosing.isEmpty || beforeClosing.last?.isWhitespace == true {
            text = beforeClosing.trimmingCharacters(in: .whitespaces)
        }
        return .heading(level: level, text: text)
    }

    private static func isDivider(_ line: Substring) -> Bool {
        let marks = line.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let marker = marks.first, "-*_".contains(marker) else {
            return false
        }
        return marks.allSatisfy { $0 == marker }
    }

    private static func listItem(_ line: Substring) -> Block? {
        guard let first = line.first else { return nil }
        let marker: String
        let remainder: Substring
        if "-*+".contains(first) {
            marker = "•"
            remainder = line.dropFirst()
        } else {
            let digits = line.prefix(while: { $0 >= "0" && $0 <= "9" })
            guard !digits.isEmpty, digits.count <= 9 else { return nil }
            let suffix = line.dropFirst(digits.count)
            guard suffix.first == "." || suffix.first == ")" else { return nil }
            marker = String(digits) + String(suffix.prefix(1))
            remainder = suffix.dropFirst()
        }
        guard remainder.first == " " || remainder.first == "\t" else { return nil }
        return .listItem(
            marker: marker,
            text: String(remainder.drop(while: { $0 == " " || $0 == "\t" }))
        )
    }
}
