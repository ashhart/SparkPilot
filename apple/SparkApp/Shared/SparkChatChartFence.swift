import Foundation

/// What a ```spark-chart fence became: a chart, a fence still arriving, or a fence the app refused.
enum SparkChatChartBlock: Equatable, Sendable {
    case ready(SparkChartSpec)
    case pending(String)
    case invalid(String, SparkChartSpecError)

    var source: String {
        switch self {
        case .ready: ""
        case .pending(let source), .invalid(let source, _): source
        }
    }
}

/// Recognises the one info string a model may use to ask for a chart, and reads what it wrote.
enum SparkChatChartFence {
    static let info = "spark-chart"

    static func matches(_ language: String?) -> Bool {
        language?.lowercased() == info
    }

    /// A chart is drawn only from a fence the model closed; until then its source stands in for it.
    static func read(_ source: String, isClosed: Bool) -> SparkChatChartBlock {
        guard isClosed else { return .pending(source) }
        switch SparkChartSpec.parse(source) {
        case .success(let spec): return .ready(spec)
        case .failure(let error): return .invalid(source, error)
        }
    }
}
