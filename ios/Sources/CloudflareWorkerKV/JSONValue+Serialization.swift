import Foundation

// A small JSON writer. JSONEncoder is not used because it escapes `/` and its
// key order is not stable across OS versions; the contract (spec §2.3) wants
// compact JSON without escaping `/`.
extension JSONValue {
    /// Compact JSON text: no whitespace, object keys sorted, `/` and non-ASCII
    /// characters written as is. Non-finite doubles are written as `null`.
    var compactJSONString: String {
        var output = ""
        write(to: &output)
        return output
    }

    /// How a value is stored as a config entry or a default (spec §2.3, §2.5):
    /// strings as is, `null` dropped (`nil`), booleans and numbers as text,
    /// arrays and objects as compact JSON.
    var entryString: String? {
        switch self {
        case .null: return nil
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return value.description
        case .array, .object: return compactJSONString
        }
    }

    private func write(to output: inout String) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .int(let value):
            output += String(value)
        case .double(let value):
            output += value.isFinite ? value.description : "null"
        case .string(let value):
            Self.writeString(value, to: &output)
        case .array(let values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 { output += "," }
                value.write(to: &output)
            }
            output += "]"
        case .object(let object):
            output += "{"
            for (index, key) in object.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                Self.writeString(key, to: &output)
                output += ":"
                object[key]!.write(to: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case _ where scalar.value < 0x20:
                output += "\\u00"
                output += hexDigit(scalar.value >> 4)
                output += hexDigit(scalar.value & 0xF)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }

    private static func hexDigit(_ value: UInt32) -> String {
        String(value, radix: 16, uppercase: false)
    }
}
