import Foundation
import Testing
@testable import CloudflareWorkerKV

// Port of flutter/test/remote_config_settings_test.dart. The preconditions
// themselves are covered by PreconditionTests (macOS).
@Suite("RemoteConfigSettings")
struct RemoteConfigSettingsTests {
    @Test("defaults to a 60 s timeout and a 12 h interval")
    func defaults() {
        let settings = RemoteConfigSettings()
        #expect(settings.fetchTimeout == 60)
        #expect(settings.minimumFetchInterval == 12 * 3_600)
        #expect(RemoteConfigSettings.defaultFetchTimeout == 60)
        #expect(RemoteConfigSettings.defaultMinimumFetchInterval == 43_200)
    }

    @Test("validates durations")
    func validates() {
        #expect(RemoteConfigSettings.problem(fetchTimeout: 0, minimumFetchInterval: 0) != nil)
        #expect(RemoteConfigSettings.problem(fetchTimeout: -1, minimumFetchInterval: 0) != nil)
        #expect(RemoteConfigSettings.problem(fetchTimeout: .nan, minimumFetchInterval: 0) != nil)
        #expect(RemoteConfigSettings.problem(fetchTimeout: .infinity, minimumFetchInterval: 0) != nil)
        #expect(RemoteConfigSettings.problem(fetchTimeout: 60, minimumFetchInterval: -1) != nil)
        #expect(RemoteConfigSettings.problem(fetchTimeout: 60, minimumFetchInterval: .infinity) != nil)
        #expect(RemoteConfigSettings.problem(fetchTimeout: 60, minimumFetchInterval: 0) == nil)
        #expect(RemoteConfigSettings(minimumFetchInterval: 0).minimumFetchInterval == 0)
    }

    @Test("json round trip")
    func roundTrip() {
        let settings = RemoteConfigSettings(fetchTimeout: 5, minimumFetchInterval: 180)
        #expect(settings.jsonValue == ["fetchTimeoutMs": 5_000, "minimumFetchIntervalMs": 180_000])
        #expect(RemoteConfigSettings(validatingMs: settings.jsonValue) == settings)
        let fractional = RemoteConfigSettings(fetchTimeout: 0.1, minimumFetchInterval: 1.5)
        #expect(RemoteConfigSettings(validatingMs: fractional.jsonValue) == fractional)
    }

    @Test("tryFromJson rejects invalid input", arguments: [
        nil,
        "x",
        [:],
        ["fetchTimeoutMs": "1", "minimumFetchIntervalMs": 1],
        ["fetchTimeoutMs": 0, "minimumFetchIntervalMs": 1],
        ["fetchTimeoutMs": 1, "minimumFetchIntervalMs": -1],
        ["fetchTimeoutMs": 1.5, "minimumFetchIntervalMs": 1],
    ] as [JSONValue?])
    func rejectsInvalid(_ json: JSONValue?) {
        #expect(RemoteConfigSettings(validatingMs: json) == nil)
    }

    @Test("description")
    func description() {
        #expect(RemoteConfigSettings(fetchTimeout: 10, minimumFetchInterval: 0).description
            == "RemoteConfigSettings(fetchTimeout: 10.0, minimumFetchInterval: 0.0)")
    }
}
