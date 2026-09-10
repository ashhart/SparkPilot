import Foundation

/// Removes what the style instruction asked for and the model wrote anyway, sparing code and quoted text.
public enum SparkChatPlainText {
    /// While a stream is running, only text before the last paragraph break is settled enough to rewrite.
    public static func cleaned(_ text: String, isComplete: Bool) -> String {
        guard !text.isEmpty else { return text }
        return isComplete ? cleanedWhole(text) : cleanedStreamPrefix(text)
    }

    private static func cleanedStreamPrefix(_ text: String) -> String {
        guard let boundary = settledBoundary(in: text) else { return text }
        let settled = cleanedWhole(String(text[text.startIndex..<boundary.lowerBound]))
        let live = String(text[boundary.upperBound...])
        return settled.isEmpty ? live : settled + "\n\n" + live
    }

    /// The last blank line that is not inside an unterminated code fence.
    static func settledBoundary(in text: String) -> Range<String.Index>? {
        var result: Range<String.Index>?
        var searchStart = text.startIndex
        while let found = text.range(of: "\n\n", range: searchStart..<text.endIndex) {
            let before = text[text.startIndex..<found.lowerBound]
            if before.components(separatedBy: "\n").filter(isFenceLine).count % 2 == 0 {
                result = found
            }
            searchStart = found.upperBound
        }
        return result
    }

    private static func cleanedWhole(_ text: String) -> String {
        var rendered: [String] = []
        for block in blocks(in: text) {
            switch block {
            case .code(let code):
                rendered.append(code)
            case .prose(let prose):
                for paragraph in prose.components(separatedBy: "\n\n") {
                    let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let cleaned = cleanedParagraph(trimmed)
                    if !cleaned.isEmpty { rendered.append(cleaned) }
                }
            }
        }
        let result = rendered.joined(separator: "\n\n")
        // An answer that was nothing but filler is shown as it came rather than erased.
        return result.isEmpty ? text : result
    }

    private enum Block {
        case prose(String)
        case code(String)
    }

    private static func isFenceLine(_ line: some StringProtocol) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private static func blocks(in text: String) -> [Block] {
        var result: [Block] = []
        var prose: [String] = []
        var code: [String] = []
        var isInFence = false
        for line in text.components(separatedBy: "\n") {
            guard isFenceLine(line) else {
                if isInFence { code.append(line) } else { prose.append(line) }
                continue
            }
            if isInFence {
                code.append(line)
                result.append(.code(code.joined(separator: "\n")))
                code = []
            } else {
                if !prose.isEmpty {
                    result.append(.prose(prose.joined(separator: "\n")))
                    prose = []
                }
                code.append(line)
            }
            isInFence.toggle()
        }
        if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))) }
        // An unterminated fence keeps every byte it has so far.
        if !code.isEmpty { result.append(.code(code.joined(separator: "\n"))) }
        return result
    }

    private static func cleanedParagraph(_ paragraph: String) -> String {
        let lines = paragraph.components(separatedBy: "\n")
        // Text the owner pasted back as a quote belongs to whoever wrote it.
        guard !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") })
        else { return paragraph }
        var text = paragraph
        if isPlainProse(lines.first ?? "") { text = withoutOpeners(text) }
        if isPlainProse(text.components(separatedBy: "\n").last ?? "") {
            text = withoutClosers(text)
        }
        return withoutSeparatorDashes(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A heading, list item, table row or quote is structure, so its first and last words stay.
    private static func isPlainProse(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        if "#>|`".contains(first) { return false }
        if "-*+".contains(first) { return !trimmed.dropFirst().hasPrefix(" ") }
        guard first.isNumber else { return true }
        let rest = trimmed.drop(while: \.isNumber)
        return !(rest.hasPrefix(". ") || rest.hasPrefix(") "))
    }

    private static func withoutOpeners(_ text: String) -> String {
        var result = text
        // Two greetings in a row is common; a third is not worth chasing.
        for _ in 0..<3 {
            guard let stripped = withoutLeadingOpener(result) else { break }
            result = stripped
        }
        return result
    }

    private static func withoutLeadingOpener(_ text: String) -> String? {
        let lower = text.lowercased()
        for phrase in SparkChatPlainStyle.openers where lower.hasPrefix(phrase) {
            // Lowercasing can change a character count, so never index past what the text has.
            guard
                var cursor = text.index(
                    text.startIndex,
                    offsetBy: phrase.count,
                    limitedBy: text.endIndex
                )
            else { continue }
            // Only a phrase closed by its own punctuation is filler; "Sure enough" is a sentence.
            guard cursor < text.endIndex else { return "" }
            guard ",!.:".contains(text[cursor]) else { continue }
            cursor = text.index(after: cursor)
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex else { return "" }
            return capitalisingFirstWord(String(text[cursor...]))
        }
        return nil
    }

    /// Leave names that start lowercase on purpose, such as iPhone or macOS, exactly as they are.
    private static func capitalisingFirstWord(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        let second = text.dropFirst().first
        guard second == nil || !(second?.isUppercase ?? false) else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func withoutClosers(_ text: String) -> String {
        var result = text
        for _ in 0..<3 {
            guard let last = sentenceRanges(in: result).last else { break }
            let sentence = result[last].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard SparkChatPlainStyle.closers.contains(where: { sentence.hasPrefix($0) }) else {
                break
            }
            result = String(result[result.startIndex..<last.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result.isEmpty { break }
        }
        return result
    }

    private static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]), next == text.endIndex || text[next].isWhitespace {
                result.append(start..<next)
                var cursor = next
                while cursor < text.endIndex, text[cursor].isWhitespace {
                    cursor = text.index(after: cursor)
                }
                start = cursor
                index = cursor
                continue
            }
            index = next
        }
        if start < text.endIndex { result.append(start..<text.endIndex) }
        return result
    }

    private enum DashRole {
        case separator
        case hyphen
    }

    private static let dashes: Set<Character> = ["\u{2014}", "\u{2013}"]

    /// Preserve attributions and numeric ranges; treat an em dash as a separator even without spaces.
    private static func withoutSeparatorDashes(_ text: String) -> String {
        let characters = Array(text)
        guard characters.contains(where: { dashes.contains($0) }) else { return text }
        let quoted = quotedPositions(in: characters)
        var roles: [Int: DashRole] = [:]
        var separatorsBySentence: [Int: [Int]] = [:]
        var sentence = 0
        for index in characters.indices {
            let character = characters[index]
            if !quoted[index], ".!?".contains(character) || character == "\n" {
                let next = index + 1
                if character == "\n" || next == characters.count || characters[next].isWhitespace {
                    sentence += 1
                }
            }
            guard dashes.contains(character), !quoted[index] else { continue }
            guard let role = role(of: index, in: characters) else { continue }
            roles[index] = role
            if role == .separator { separatorsBySentence[sentence, default: []].append(index) }
        }
        // A pair inside one sentence brackets an aside, so it reads as commas; a lone one introduces.
        var replacements: [Int: Character] = [:]
        for (_, positions) in separatorsBySentence {
            let mark: Character = positions.count == 1 ? ":" : ","
            for position in positions { replacements[position] = mark }
        }
        return rebuilt(characters, replacements: replacements, roles: roles)
    }

    private static func role(of index: Int, in characters: [Character]) -> DashRole? {
        let lineStart = characters[..<index].lastIndex(of: "\n").map { $0 + 1 } ?? 0
        if characters[lineStart..<index].allSatisfy(\.isWhitespace) { return nil }
        let before = characters[..<index].last
        let after = index + 1 < characters.count ? characters[index + 1] : nil
        let priorText = characters[..<index].last(where: { !$0.isWhitespace })
        let laterText = characters[(index + 1)...].first(where: { !$0.isWhitespace })
        // A range between two numbers is punctuation the model got right.
        if priorText?.isNumber == true, laterText?.isNumber == true { return nil }
        // A dash that opens a line is an attribution or a bullet, not a mark inside a sentence.
        if opensLine(index, in: characters) { return nil }
        // Only an en dash between words is the compound hyphen the model mistyped; an em dash is always a separator, spaced or not.
        if characters[index] == "\u{2013}",
            before?.isLetter == true || before?.isNumber == true,
            after?.isLetter == true || after?.isNumber == true
        {
            return characters[index] == "\u{2014}" ? .separator : .hyphen
        }
        return .separator
    }

    /// True when nothing but whitespace stands between this dash and the start of its line.
    private static func opensLine(_ index: Int, in characters: [Character]) -> Bool {
        for character in characters[..<index].reversed() {
            if character == "\n" { return true }
            if !character.isWhitespace { return false }
        }
        return true
    }

    private static func rebuilt(
        _ characters: [Character],
        replacements: [Int: Character],
        roles: [Int: DashRole]
    ) -> String {
        var output = ""
        output.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            if let mark = replacements[index] {
                while let last = output.last, last == " " || last == "\t" { output.removeLast() }
                output.append(mark)
                output.append(" ")
                index += 1
                while index < characters.count,
                    characters[index] == " " || characters[index] == "\t"
                {
                    index += 1
                }
                continue
            }
            output.append(roles[index] == .hyphen ? "-" : characters[index])
            index += 1
        }
        return output
    }

    /// Flags every character inside a code span or a quotation, including its own delimiters.
    private static func quotedPositions(in characters: [Character]) -> [Bool] {
        var result = [Bool](repeating: false, count: characters.count)
        var isInCode = false
        var isInQuote = false
        for index in characters.indices {
            let character = characters[index]
            if character == "`" {
                isInCode.toggle()
                result[index] = true
                continue
            }
            if !isInCode, character == "\"" {
                isInQuote.toggle()
                result[index] = true
                continue
            }
            if !isInCode, character == "\u{201C}" {
                isInQuote = true
                result[index] = true
                continue
            }
            if !isInCode, character == "\u{201D}" {
                isInQuote = false
                result[index] = true
                continue
            }
            result[index] = isInCode || isInQuote
        }
        return result
    }
}

/// Renders a growing answer without rewriting the paragraphs that have already settled.
public struct SparkChatPlainTextStream {
    private var settledSource = ""
    private var settledRender = ""
    /// Counts the rewrites, so a test can prove settled text is not processed again.
    public private(set) var settledRenderCount = 0

    public init() {}

    public mutating func rendered(_ text: String, isComplete: Bool) -> String {
        guard !isComplete else { return SparkChatPlainText.cleaned(text, isComplete: true) }
        guard let boundary = SparkChatPlainText.settledBoundary(in: text) else { return text }
        let source = String(text[text.startIndex..<boundary.lowerBound])
        if source != settledSource {
            settledSource = source
            settledRender = SparkChatPlainText.cleaned(source, isComplete: true)
            settledRenderCount += 1
        }
        let live = String(text[boundary.upperBound...])
        return settledRender.isEmpty ? live : settledRender + "\n\n" + live
    }
}
