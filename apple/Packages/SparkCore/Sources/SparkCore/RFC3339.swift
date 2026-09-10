import Foundation

/// Parse protocol-defined RFC 3339 offsets and fractional seconds without shared non-Sendable Foundation formatters.
public enum RFC3339 {
    public static func date(from text: String) -> Date? {
        let characters = Array(text.utf8)
        // The shortest legal form is "YYYY-MM-DDThh:mm:ssZ".
        guard characters.count >= 20 else { return nil }

        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = characters[index]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        func isByte(_ index: Int, _ options: [Unicode.Scalar]) -> Bool {
            index < characters.count && options.contains { characters[index] == UInt8(ascii: $0) }
        }

        guard let year = digits(0..<4), isByte(4, ["-"]),
            let month = digits(5..<7), isByte(7, ["-"]),
            let day = digits(8..<10), isByte(10, ["T", "t"]),
            let hour = digits(11..<13), isByte(13, [":"]),
            let minute = digits(14..<16), isByte(16, [":"]),
            let second = digits(17..<19)
        else { return nil }

        var index = 19
        var nanoseconds = 0
        if isByte(index, ["."]) {
            index += 1
            var scale = 100_000_000
            var seen = 0
            while index < characters.count,
                characters[index] >= UInt8(ascii: "0"),
                characters[index] <= UInt8(ascii: "9")
            {
                if scale > 0 {
                    nanoseconds += Int(characters[index] - UInt8(ascii: "0")) * scale
                    scale /= 10
                }
                index += 1
                seen += 1
            }
            guard seen > 0 else { return nil }
        }

        var offsetSeconds = 0
        if isByte(index, ["Z", "z"]) {
            index += 1
        } else if isByte(index, ["+", "-"]) {
            let negative = characters[index] == UInt8(ascii: "-")
            index += 1
            guard index + 5 <= characters.count,
                let offsetHour = digits(index..<(index + 2)),
                characters[index + 2] == UInt8(ascii: ":"),
                let offsetMinute = digits((index + 3)..<(index + 5)),
                offsetHour < 24, offsetMinute < 60
            else { return nil }
            offsetSeconds = offsetHour * 3600 + offsetMinute * 60
            if negative { offsetSeconds = -offsetSeconds }
            index += 5
        } else {
            // Require an explicit RFC 3339 offset to keep signature windows unambiguous.
            return nil
        }

        guard index == characters.count else { return nil }
        guard month >= 1, month <= 12, day >= 1, day <= 31,
            hour < 24, minute < 60, second <= 60
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        // Fold RFC 3339 leap seconds onto the following representable Foundation instant.
        components.second = min(second, 59)
        components.nanosecond = nanoseconds

        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        // Reject dates that do not exist, such as 31 February.
        guard let date = calendar.date(from: components),
            let normalised = calendar.dateComponents(
                [.year, .month, .day],
                from: date
            ) as DateComponents?,
            normalised.year == year, normalised.month == month, normalised.day == day
        else { return nil }

        return date.addingTimeInterval(TimeInterval(-offsetSeconds))
    }

    /// Format an instant the way the runtime does: UTC, second precision, `Z`.
    public static func string(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }
}
