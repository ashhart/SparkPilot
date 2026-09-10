import Foundation

/// Emit cross-language canonical signing bytes as specified in docs/build/APPLE-BOUNDARIES.md and pinned by the shared manifest fixture.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// Keep manifest integers exact because binary floating-point cannot preserve the cross-language signing representation.
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public enum CanonicalJSONError: Error, Equatable, Sendable {
    /// Reject fractional manifest numbers rather than guessing a cross-language canonical representation.
    case unsupportedNumber(Double)
    case notAnObject
}

extension JSONValue: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // Bool before the numeric cases: JSON `true` is not 1.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "value is not JSON this decoder understands"
        )
    }
}

extension JSONValue {
    /// Parse a JSON document.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// This value's members, if it is an object.
    public var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var integerValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The canonical bytes of this value.
    public func canonicalBytes() throws -> Data {
        var output = String()
        try write(into: &output)
        return Data(output.utf8)
    }

    /// Remove the top-level signature member before computing its signing input.
    public func canonicalBytes(excludingTopLevel member: String) throws -> Data {
        guard case .object(var members) = self else {
            throw CanonicalJSONError.notAnObject
        }
        members.removeValue(forKey: member)
        return try JSONValue.object(members).canonicalBytes()
    }

    private func write(into output: inout String) throws {
        switch self {
        case .null:
            // Omit object nulls while preserving null array elements required by JSON.
            output += "null"

        case .bool(let value):
            output += value ? "true" : "false"

        case .integer(let value):
            output += String(value)

        case .double(let value):
            // A whole number that arrived as a double is still exact.
            if value == value.rounded(), value.magnitude < 9.007_199_254_740_992e15 {
                output += String(Int64(value))
            } else {
                throw CanonicalJSONError.unsupportedNumber(value)
            }

        case .string(let value):
            JSONValue.write(string: value, into: &output)

        case .array(let elements):
            output += "["
            for (index, element) in elements.enumerated() {
                if index > 0 { output += "," }
                try element.write(into: &output)
            }
            output += "]"

        case .object(let members):
            // Remove null object members and order remaining keys by UTF-8 bytes to match Rust and Python.
            let ordered =
                members
                .filter { $0.value != .null }
                .sorted { left, right in
                    Array(left.key.utf8).lexicographicallyPrecedes(Array(right.key.utf8))
                }
            output += "{"
            for (index, member) in ordered.enumerated() {
                if index > 0 { output += "," }
                JSONValue.write(string: member.key, into: &output)
                output += ":"
                try member.value.write(into: &output)
            }
            output += "}"
        }
    }

    /// Escape only characters required by the canonical JSON format.
    private static func write(string value: String, into output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\u{08}":
                output += "\\b"
            case "\u{09}":
                output += "\\t"
            case "\u{0A}":
                output += "\\n"
            case "\u{0C}":
                output += "\\f"
            case "\u{0D}":
                output += "\\r"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    // Emit solidus and non-ASCII scalars unchanged.
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
