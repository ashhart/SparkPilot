import Foundation

/// Reads a `spark-chart` body into a bounded spec, refusing anything the drawing code would have to guess at.
struct SparkChartSpecReader {
    private static let chartFields: Set<String> = [
        "type", "title", "stacked", "x", "y", "series", "annotations",
    ]
    private static let seriesFields: Set<String> = ["name", "points"]
    private static let pointFields: Set<String> = ["x", "y"]
    private static let annotationFields: Set<String> = ["text", "x", "y"]

    func read(_ source: String) -> Result<SparkChartSpec, SparkChartSpecError> {
        do {
            return .success(try spec(source))
        } catch let error as SparkChartSpecError {
            return .failure(error)
        } catch {
            return .failure(.malformed)
        }
    }

    private func spec(_ source: String) throws -> SparkChartSpec {
        guard source.utf8.count <= SparkChartLimits.sourceBytes else {
            throw SparkChartSpecError.tooLarge
        }
        let root = try object(
            try JSONSerialization.jsonObject(with: Data(source.utf8))
        )
        try reject(unknownIn: root, allowed: Self.chartFields)
        let kind = try chartKind(root)
        let title = try text(root, "title", limit: SparkChartLimits.titleCharacters, required: true)
        let stacked = try stacking(root, kind: kind)
        let x = try axis(root, "x", allowsKind: true)
        let y = try axis(root, "y", allowsKind: false)
        let rawSeries = try list(root, "series")
        guard !rawSeries.isEmpty else { throw SparkChartSpecError.emptySeries }
        guard rawSeries.count <= SparkChartLimits.series else {
            throw SparkChartSpecError.tooManySeries
        }
        let valueKind = try declaredValueKind(root, rawSeries: rawSeries)
        let series = try rawSeries.map { try readSeries($0, valueKind: valueKind, kind: kind) }
        try checkTotals(series)
        let spec = SparkChartSpec(
            kind: kind,
            title: title ?? "",
            isStacked: stacked,
            x: x,
            y: y,
            valueKind: valueKind,
            series: series,
            annotations: try annotations(root, valueKind: valueKind)
        )
        try checkShape(spec)
        return spec
    }

    // MARK: - Header

    private func chartKind(_ root: [String: Any]) throws -> SparkChartKind {
        guard let raw = root["type"] else { throw SparkChartSpecError.missingField }
        guard let name = raw as? String, let kind = SparkChartKind(rawValue: name) else {
            throw SparkChartSpecError.unknownType
        }
        return kind
    }

    /// Stacking is a property of bars and areas; declaring it anywhere else is a misunderstanding, not a default.
    private func stacking(_ root: [String: Any], kind: SparkChartKind) throws -> Bool {
        guard let raw = root["stacked"] else { return false }
        guard kind.allowsStacking else { throw SparkChartSpecError.stackingUnsupported }
        guard isBoolean(raw), let value = raw as? Bool else { throw SparkChartSpecError.malformed }
        return value
    }

    private func axis(_ root: [String: Any], _ key: String, allowsKind: Bool) throws
        -> SparkChartAxis
    {
        guard let raw = root[key] else { return .none }
        let fields = try object(raw)
        try reject(
            unknownIn: fields,
            allowed: allowsKind ? ["label", "unit", "kind"] : ["label", "unit"]
        )
        return SparkChartAxis(
            label: try text(fields, "label", limit: SparkChartLimits.labelCharacters),
            unit: try text(fields, "unit", limit: SparkChartLimits.unitCharacters)
        )
    }

    /// A declared kind is a promise the points must keep; without one the first point decides for every point.
    private func declaredValueKind(_ root: [String: Any], rawSeries: [Any]) throws
        -> SparkChartValueKind
    {
        if let fields = root["x"].map({ try? object($0) }) ?? nil,
            let declared = fields["kind"]
        {
            guard let name = declared as? String, let kind = SparkChartValueKind(rawValue: name)
            else { throw SparkChartSpecError.unknownType }
            return kind
        }
        let first = try object(rawSeries[0])
        let points = try list(first, "points")
        guard let point = points.first else { throw SparkChartSpecError.emptySeries }
        guard let raw = try object(point)["x"] else { throw SparkChartSpecError.missingField }
        return try value(raw).kind
    }

    // MARK: - Series and points

    private func readSeries(_ raw: Any, valueKind: SparkChartValueKind, kind: SparkChartKind) throws
        -> SparkChartSeries
    {
        let fields = try object(raw)
        try reject(unknownIn: fields, allowed: Self.seriesFields)
        guard
            let name = try text(
                fields,
                "name",
                limit: SparkChartLimits.nameCharacters,
                required: true
            )
        else { throw SparkChartSpecError.missingField }
        let raw = try list(fields, "points")
        guard !raw.isEmpty else { throw SparkChartSpecError.emptySeries }
        guard raw.count <= SparkChartLimits.pointsPerSeries else {
            throw SparkChartSpecError.tooManyPoints
        }
        var seen: Set<SparkChartValue> = []
        let points = try raw.map { entry -> SparkChartPoint in
            let point = try readPoint(entry, valueKind: valueKind)
            guard kind == .scatter || seen.insert(point.x).inserted else {
                throw SparkChartSpecError.repeatedValue
            }
            return point
        }
        return SparkChartSeries(name: name, points: points)
    }

    private func readPoint(_ raw: Any, valueKind: SparkChartValueKind) throws -> SparkChartPoint {
        let fields = try object(raw)
        try reject(unknownIn: fields, allowed: Self.pointFields)
        guard let rawX = fields["x"], let rawY = fields["y"] else {
            throw SparkChartSpecError.missingField
        }
        let x = try value(rawX)
        guard x.kind == valueKind else { throw SparkChartSpecError.mixedValues }
        return SparkChartPoint(x: x, y: try number(rawY))
    }

    private func checkTotals(_ series: [SparkChartSeries]) throws {
        guard series.reduce(0, { $0 + $1.points.count }) <= SparkChartLimits.points else {
            throw SparkChartSpecError.tooManyPoints
        }
        var names: Set<String> = []
        for entry in series where !names.insert(entry.name).inserted {
            throw SparkChartSpecError.duplicateSeries
        }
    }

    /// Circular charts describe one whole, so more than one series or a negative slice has no meaning.
    private func checkShape(_ spec: SparkChartSpec) throws {
        guard spec.kind.isCircular else { return }
        guard spec.series.count == 1, spec.valueKind == .category,
            spec.values.allSatisfy({ $0 >= 0 })
        else { throw SparkChartSpecError.pieShape }
    }

    // MARK: - Annotations

    private func annotations(_ root: [String: Any], valueKind: SparkChartValueKind) throws
        -> [SparkChartAnnotation]
    {
        guard let raw = root["annotations"] else { return [] }
        guard let entries = raw as? [Any] else { throw SparkChartSpecError.malformed }
        guard entries.count <= SparkChartLimits.annotations else {
            throw SparkChartSpecError.tooManyAnnotations
        }
        return try entries.map { entry in
            let fields = try object(entry)
            try reject(unknownIn: fields, allowed: Self.annotationFields)
            guard
                let text = try text(
                    fields,
                    "text",
                    limit: SparkChartLimits.annotationCharacters,
                    required: true
                )
            else { throw SparkChartSpecError.missingField }
            var annotation = SparkChartAnnotation(text: text)
            if let rawX = fields["x"] {
                let x = try value(rawX)
                guard x.kind == valueKind else { throw SparkChartSpecError.mixedValues }
                annotation.x = x
            }
            if let rawY = fields["y"] { annotation.y = try number(rawY) }
            return annotation
        }
    }

    // MARK: - Primitives

    private func object(_ raw: Any) throws -> [String: Any] {
        guard let fields = raw as? [String: Any] else { throw SparkChartSpecError.malformed }
        return fields
    }

    private func list(_ fields: [String: Any], _ key: String) throws -> [Any] {
        guard let raw = fields[key] else { throw SparkChartSpecError.missingField }
        guard let entries = raw as? [Any] else { throw SparkChartSpecError.malformed }
        return entries
    }

    private func reject(unknownIn fields: [String: Any], allowed: Set<String>) throws {
        guard fields.keys.allSatisfy(allowed.contains) else {
            throw SparkChartSpecError.unknownField
        }
    }

    private func text(
        _ fields: [String: Any],
        _ key: String,
        limit: Int,
        required: Bool = false
    ) throws -> String? {
        guard let raw = fields[key] else {
            if required { throw SparkChartSpecError.missingField }
            return nil
        }
        guard let value = raw as? String, !isBoolean(raw) else {
            throw SparkChartSpecError.malformed
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SparkChartSpecError.missingField }
        guard trimmed.count <= limit else { throw SparkChartSpecError.textTooLong }
        return trimmed
    }

    private func number(_ raw: Any) throws -> Double {
        guard !isBoolean(raw), let value = (raw as? NSNumber)?.doubleValue, value.isFinite else {
            throw SparkChartSpecError.notANumber
        }
        return value
    }

    private func value(_ raw: Any) throws -> SparkChartValue {
        if !isBoolean(raw), let number = raw as? NSNumber, number.doubleValue.isFinite {
            return .number(number.doubleValue)
        }
        guard let text = raw as? String else { throw SparkChartSpecError.malformed }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SparkChartSpecError.missingField }
        if let date = ISO8601DateFormatter.sparkChartValue(trimmed) { return .date(date) }
        guard trimmed.count <= SparkChartLimits.categoryCharacters else {
            throw SparkChartSpecError.textTooLong
        }
        return .category(trimmed)
    }

    private func isBoolean(_ raw: Any) -> Bool {
        (raw as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }
}
