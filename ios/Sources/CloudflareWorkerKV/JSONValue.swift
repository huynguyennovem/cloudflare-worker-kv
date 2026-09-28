import Foundation

/// A JSON value.
///
/// Use it for structured defaults, which are stored as compact JSON text:
///
/// ```swift
/// remoteConfig.setDefaults([
///     "ad_units": ["banner": "ca-app-pub-1", "sizes": [320, 728]] as JSONValue,
/// ])
/// ```
///
/// ``RemoteConfigValue/jsonValue`` parses a value back into a `JSONValue`.
///
/// Decoding keeps booleans and numbers apart (`true` is never `1`), and
/// integers that fit in 64 bits are kept as ``int(_:)``.
public enum JSONValue: Sendable, Hashable {
    /// `null`.
    case null
    /// `true` or `false`.
    case bool(Bool)
    /// A number without a fraction or exponent that fits in 64 bits.
    case int(Int64)
    /// Any other number.
    case double(Double)
    /// A string.
    case string(String)
    /// An array.
    case array([JSONValue])
    /// An object. Key order is not preserved.
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    /// Decodes any JSON value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // The order matters: Bool before the numbers so that `1` never becomes
        // `true`, and Int64 before Double so that integers stay integers.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a JSON value.")
        }
    }

    /// Encodes the value.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    /// Parses JSON text, including top-level scalars such as `"x"` or `42`.
    init(parsing data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The value of `key` when this is an object, otherwise `nil`.
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }
}
