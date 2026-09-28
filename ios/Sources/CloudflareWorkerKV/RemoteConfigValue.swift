import Foundation

/// A config value with typed accessors.
///
/// Values are stored as strings and converted on read. Conversions never
/// fail: when a value cannot be converted, the type's static default is
/// returned instead (`""`, `0`, `0.0`, `false`).
///
/// ```swift
/// let maxItems = remoteConfig["max_items"].intValue
/// let source = remoteConfig["max_items"].source // .remote, .default or .static
/// ```
public struct RemoteConfigValue: Sendable, Hashable, CustomStringConvertible {
    /// Returned by ``stringValue`` for static values.
    public static let defaultValueForString = ""

    /// Returned by ``intValue`` for static or non-integer values.
    public static let defaultValueForInt = 0

    /// Returned by ``doubleValue`` for static or non-numeric values.
    public static let defaultValueForDouble = 0.0

    /// Returned by ``boolValue`` for static values.
    public static let defaultValueForBool = false

    private static let trueValues: Set<String> = ["1", "true", "t", "yes", "y", "on"]

    /// The raw string, `nil` for static values.
    let rawValue: String?

    /// Where the value came from.
    public let source: RemoteConfigSource

    /// Creates a value from its raw string, which is `nil` for static
    /// (unknown key) values.
    public init(_ rawValue: String?, source: RemoteConfigSource) {
        self.rawValue = rawValue
        self.source = source
    }

    /// The raw value, or `""` for static values.
    public var stringValue: String {
        rawValue ?? Self.defaultValueForString
    }

    /// `true` when the trimmed, lowercased value is one of
    /// `1`, `true`, `t`, `yes`, `y`, `on`; `false` otherwise.
    public var boolValue: Bool {
        guard let trimmed else { return Self.defaultValueForBool }
        return Self.trueValues.contains(trimmed.lowercased())
    }

    /// The trimmed value parsed as a decimal integer with an optional sign,
    /// or `0`. `"10.0"` gives `0`.
    public var intValue: Int {
        guard let trimmed else { return Self.defaultValueForInt }
        return Int(trimmed, radix: 10) ?? Self.defaultValueForInt
    }

    /// The trimmed value parsed as a decimal number with an optional fraction
    /// and exponent, or `0.0`.
    public var doubleValue: Double {
        guard let trimmed, Self.isDecimalNumber(trimmed) else {
            return Self.defaultValueForDouble
        }
        return Double(trimmed) ?? Self.defaultValueForDouble
    }

    /// ``doubleValue`` as an `NSNumber`.
    public var numberValue: NSNumber {
        NSNumber(value: doubleValue)
    }

    /// ``stringValue`` encoded as UTF-8.
    public var dataValue: Data {
        Data(stringValue.utf8)
    }

    /// The value parsed as JSON, or `nil` when it is not valid JSON.
    public var jsonValue: JSONValue? {
        try? JSONValue(parsing: dataValue)
    }

    /// Decodes the value, as JSON, into `Value`.
    ///
    /// ```swift
    /// struct AdUnits: Decodable { let banner: String }
    /// let units = try remoteConfig["ad_units"].decoded(asType: AdUnits.self)
    /// ```
    ///
    /// - Throws: A `DecodingError` when the value is not valid JSON for `Value`.
    public func decoded<Value: Decodable>(asType: Value.Type = Value.self) throws -> Value {
        try JSONDecoder().decode(Value.self, from: dataValue)
    }

    public var description: String {
        let raw = rawValue.map { "\"\($0)\"" } ?? "nil"
        return "RemoteConfigValue(\(raw), source: .\(source.rawValue))"
    }

    private var trimmed: String? {
        rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `[+-]?(digits[.digits?] | .digits)([eE][+-]?digits)?`, ASCII only.
    /// Rejects what `Double(_:)` would otherwise accept (`nan`, `inf`, hex).
    private static func isDecimalNumber(_ text: String) -> Bool {
        var bytes = Substring(text).utf8[...]
        func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
        func skipDigits() -> Int {
            var count = 0
            while let byte = bytes.first, isDigit(byte) {
                bytes.removeFirst()
                count += 1
            }
            return count
        }
        if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
            bytes.removeFirst()
        }
        var mantissaDigits = skipDigits()
        if bytes.first == UInt8(ascii: ".") {
            bytes.removeFirst()
            mantissaDigits += skipDigits()
        }
        guard mantissaDigits > 0 else { return false }
        if let e = bytes.first, e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            bytes.removeFirst()
            if let sign = bytes.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                bytes.removeFirst()
            }
            guard skipDigits() > 0 else { return false }
        }
        return bytes.isEmpty
    }
}
