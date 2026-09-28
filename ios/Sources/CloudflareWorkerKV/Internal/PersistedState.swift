import Foundation

/// The persisted cache, format version 1, shared with the other SDKs
/// (spec §2.8):
///
/// ```json
/// {"formatVersion": 1, "active": {"version": "v1", "entries": {"k": "v"}},
///  "fetched": null, "etag": "\"v1\"", "lastSuccessfulFetchMs": 1767225600000,
///  "throttleEndMs": null, "lastFetchStatus": "success",
///  "settings": {"fetchTimeoutMs": 60000, "minimumFetchIntervalMs": 43200000}}
/// ```
struct PersistedState: Sendable, Equatable {
    static let formatVersion: Int64 = 1
    static let keyPrefix = "cloudflare_worker_kv:"

    var active: ConfigSnapshot?
    var fetched: ConfigSnapshot?
    var etag: String?
    var lastSuccessfulFetch: Date?
    var throttleEndTime: Date?
    var lastFetchStatus: RemoteConfigFetchStatus = .noFetchYet
    var settings = RemoteConfigSettings()

    /// The storage key of an endpoint/template pair.
    static func storageKey(endpoint: URL, template: String) -> String {
        "\(keyPrefix)\(endpoint.absoluteString)|\(template)"
    }

    /// The JSON text to store. Missing values are written as `null`.
    var encoded: String {
        let object: JSONValue = [
            "formatVersion": .int(Self.formatVersion),
            "active": active?.jsonValue ?? .null,
            "fetched": fetched?.jsonValue ?? .null,
            "etag": etag.map(JSONValue.string) ?? .null,
            "lastSuccessfulFetchMs": lastSuccessfulFetch.map { .int(Self.milliseconds($0)) } ?? .null,
            "throttleEndMs": throttleEndTime.map { .int(Self.milliseconds($0)) } ?? .null,
            "lastFetchStatus": .string(lastFetchStatus.rawValue),
            "settings": settings.jsonValue,
        ]
        return object.compactJSONString
    }

    /// Restores a stored state, leniently, like the Flutter SDK:
    ///
    /// - text that is not a JSON object, or has another `formatVersion`,
    ///   gives `nil` (start from a clean state);
    /// - a malformed snapshot throws (start from a clean state);
    /// - other invalid fields fall back to their defaults.
    static func decode(_ raw: String) throws -> PersistedState? {
        guard let json = try? JSONValue(parsing: Data(raw.utf8)),
              case .object(let object) = json,
              object["formatVersion"] == .int(formatVersion)
        else { return nil }

        var state = PersistedState()
        state.active = try snapshot(object["active"])
        state.fetched = try snapshot(object["fetched"])
        if case .string(let etag)? = object["etag"] { state.etag = etag }
        state.lastSuccessfulFetch = date(object["lastSuccessfulFetchMs"])
        state.throttleEndTime = date(object["throttleEndMs"])
        if case .string(let name)? = object["lastFetchStatus"],
           let status = RemoteConfigFetchStatus(rawValue: name) {
            state.lastFetchStatus = status
        }
        state.settings = RemoteConfigSettings(validatingMs: object["settings"]) ?? RemoteConfigSettings()
        return state
    }

    private static func snapshot(_ json: JSONValue?) throws -> ConfigSnapshot? {
        guard let json, json != .null else { return nil }
        return try ConfigSnapshot(json: json)
    }

    private static func date(_ json: JSONValue?) -> Date? {
        guard case .int(let ms)? = json else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        let ms = (date.timeIntervalSince1970 * 1000).rounded(.down)
        if ms >= 9.2e18 { return .max }
        if ms <= -9.2e18 { return .min }
        return Int64(ms)
    }
}
