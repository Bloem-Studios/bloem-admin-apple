import Foundation

/// Any JSON value, kept with its type: a stored setting is whatever JSON the apps saved, and an
/// edit has to write back the same JSON type (an integer stays an integer, a flag stays a flag).
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var isNull: Bool { self == .null }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The value as the person reads and edits it: a string as is, a number without a trailing
    /// ".0", `true`/`false`, and an empty string for null. Arrays and objects are shown as JSON.
    var editText: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .string(let value): return value
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self), let text = String(data: data, encoding: .utf8) else { return "" }
            return text
        }
    }
}
