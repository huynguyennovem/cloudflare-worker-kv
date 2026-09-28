import Foundation

/// An immutable set of remote entries plus the version the Worker assigned.
struct ConfigSnapshot: Sendable, Hashable {
    /// Thrown when a payload does not have the `{"entries": {...}}` shape.
    struct FormatError: Error, CustomStringConvertible {
        let description: String
    }

    static let empty = ConfigSnapshot(version: "", entries: [:])

    /// Opaque version identifier (the Worker uses a SHA-256 of the entries).
    let version: String

    /// Parameter values, always strings.
    let entries: [String: String]

    init(version: String, entries: [String: String]) {
        self.version = version
        self.entries = entries
    }

    /// Parses `{"version": "...", "entries": {...}}` (spec §2.3).
    ///
    /// Entry values are normalised like the Worker does: strings as is,
    /// `null` dropped, booleans and numbers as text, arrays and objects as
    /// compact JSON. `version` falls back to `fallbackVersion`, then `""`,
    /// when it is not a string.
    init(json: JSONValue, fallbackVersion: String? = nil) throws {
        guard case .object(let object) = json else {
            throw FormatError(description: "Config payload must be a JSON object.")
        }
        guard case .object(let rawEntries)? = object["entries"] else {
            throw FormatError(description: "\"entries\" must be a JSON object.")
        }
        var entries: [String: String] = [:]
        for (key, value) in rawEntries {
            if let string = value.entryString { entries[key] = string }
        }
        let version: String
        if case .string(let string)? = object["version"] {
            version = string
        } else {
            version = fallbackVersion ?? ""
        }
        self.init(version: version, entries: entries)
    }

    /// The persisted form, `{"version": ..., "entries": {...}}`.
    var jsonValue: JSONValue {
        ["version": .string(version), "entries": .object(entries.mapValues(JSONValue.string))]
    }
}
