import Foundation

extension LocalizedStringResource {
    static func widgetMemoryTotal(_ total: String) -> Self {
        .init(
            "widget.memory.total",
            defaultValue: "of \(total) used",
            comment: "Widget memory capacity below the used amount."
        )
    }
    static func widgetMemoryValue(used: String, total: String) -> Self {
        .init(
            "widget.memory.accessibility",
            defaultValue: "\(used) of \(total)",
            comment: "Accessible memory used and total values, including units."
        )
    }
    static func widgetMemoryCoverage(reporting: Int, expected: Int) -> Self {
        .init(
            "widget.memory.coverage",
            defaultValue: "\(reporting) of \(expected) reporting",
            comment: "Members with a memory reading, out of the total members."
        )
    }
    /// Say how old a reading is rather than showing a stale number as if it were current.
    public static func widgetLastChecked(_ elapsed: String) -> Self {
        .init(
            "widget.last.checked",
            defaultValue: "Last checked \(elapsed) ago",
            comment: "Ages a widget reading the app could not refresh."
        )
    }

    static func widgetOnline(connected: Int, total: Int) -> Self {
        .init(
            "widget.online",
            defaultValue: "\(connected) of \(total) online",
            comment: "Connected targets out of all saved targets."
        )
    }
}
