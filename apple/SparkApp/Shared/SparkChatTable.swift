import Foundation

/// Finds a Markdown table in an answer and turns its numeric columns into a chart on this device.
enum SparkChatTable {
    struct Table: Equatable, Sendable {
        let headers: [String]
        let rows: [[String]]
        /// Which lines of the text the table occupies, so the prose around it stays prose.
        let lines: Range<Int>
    }

    /// Beyond this a grid costs more to lay out than it earns; the text stands on its own.
    static let renderedRows = 200

    /// Reads the first table in a block of text; a header row and its dashes are what make one.
    static func first(in text: String) -> Table? {
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where index + 2 <= lines.count - 1 {
            let headers = cells(line)
            guard headers.count >= 2, headers.allSatisfy({ !$0.isEmpty }),
                isDelimiter(lines[index + 1], columns: headers.count)
            else { continue }
            var rows: [[String]] = []
            for row in lines.dropFirst(index + 2) {
                let values = cells(row)
                guard values.count == headers.count, row.contains("|") else { break }
                rows.append(values)
            }
            guard !rows.isEmpty else { continue }
            return Table(
                headers: headers,
                rows: rows,
                lines: index..<(index + 2 + rows.count)
            )
        }
        return nil
    }

    /// Builds the documented chart object and reads it back, so a table is held to the same limits.
    static func chart(_ table: Table) -> SparkChartSpec? {
        let columns = numericColumns(table)
        guard !columns.isEmpty else { return nil }
        let labels = table.rows.map { $0[0] }
        let single = columns.count == 1 ? columns[0] : nil
        var object: [String: Any] = [
            "type": kind(for: labels).rawValue,
            "title": title(columns.map(\.name), label: table.headers[0]),
            "series": columns.map { column in
                [
                    "name": column.name,
                    "points": zip(labels, column.values).map { ["x": value($0), "y": $1] },
                ]
            },
        ]
        if !table.headers[0].isEmpty { object["x"] = ["label": table.headers[0]] }
        var y: [String: Any] = [:]
        if let single {
            y["label"] = single.name
            if let unit = single.unit { y["unit"] = unit }
        }
        if !y.isEmpty { object["y"] = y }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? SparkChartSpec.parse(String(decoding: data, as: UTF8.self)).get()
    }

    private struct Column {
        let name: String
        let unit: String?
        let values: [Double]
    }

    // MARK: - Reading a table

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return [] }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isDelimiter(_ line: String, columns: Int) -> Bool {
        let marks = cells(line)
        guard marks.count == columns else { return false }
        return marks.allSatisfy { mark in
            var body = Substring(mark)
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    // MARK: - Reading its numbers

    private static func numericColumns(_ table: Table) -> [Column] {
        table.headers.indices.dropFirst().compactMap { index in
            let cells = table.rows.map { $0[index] }
            let values = cells.compactMap(number)
            guard values.count == cells.count else { return nil }
            let (name, unit) = heading(table.headers[index])
            let percent = cells.allSatisfy { $0.hasSuffix("%") }
            return Column(name: name, unit: unit ?? (percent ? "%" : nil), values: values)
        }
    }

    /// A unit in brackets after a heading belongs on the axis, not in the series' name.
    private static func heading(_ header: String) -> (String, String?) {
        for (open, close) in [("(", ")"), ("[", "]")] where header.hasSuffix(close) {
            guard let start = header.range(of: open, options: .backwards) else { continue }
            let unit = header[start.upperBound...].dropLast()
                .trimmingCharacters(in: .whitespaces)
            let name = header[..<start.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !unit.isEmpty, !name.isEmpty else { continue }
            return (name, unit)
        }
        return (header, nil)
    }

    private static func number(_ cell: String) -> Double? {
        var text = cell.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("%") { text.removeLast() }
        // Require three-digit thousands groups so a decimal comma such as 1,5 never becomes 15.
        for separator in [",", " ", "\u{00A0}", "\u{202F}"] where text.contains(separator) {
            let grouped =
                "^[+-]?[0-9]{1,3}(" + NSRegularExpression.escapedPattern(for: separator)
                + "[0-9]{3})+(\\.[0-9]+)?$"
            guard text.range(of: grouped, options: .regularExpression) != nil else { return nil }
            text = text.replacingOccurrences(of: separator, with: "")
        }
        let shape = /^[+-]?[0-9]+(\.[0-9]+)?$/
        guard text.wholeMatch(of: shape) != nil else { return nil }
        return Double(text)
    }

    // MARK: - Shaping the chart

    private static func kind(for labels: [String]) -> SparkChartKind {
        let plotted = labels.allSatisfy {
            number($0) != nil || ISO8601DateFormatter.sparkChartValue($0) != nil
        }
        return plotted ? .line : .bar
    }

    private static func value(_ label: String) -> Any {
        number(label) ?? label
    }

    private static func title(_ names: [String], label: String) -> String {
        let listed = names.formatted(.list(type: .and))
        let full =
            label.isEmpty
            ? listed : String(localized: .chartOfSeriesBy(series: listed, label: label))
        return String(full.prefix(SparkChartLimits.titleCharacters))
    }
}
