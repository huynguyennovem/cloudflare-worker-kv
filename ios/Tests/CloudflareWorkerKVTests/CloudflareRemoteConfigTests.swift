import Foundation
import Testing
@testable import CloudflareWorkerKV

// Port of flutter/test/cloudflare_remote_config_test.dart: one suite per Dart
// group, with the same test names. Swift-only tests are marked as such.

private let endpoint = URL(string: "https://cfg.example.com")!
private let defaultKey = "cloudflare_worker_kv:https://cfg.example.com|default"

/// The Dart `setUp`: a fake Worker, an in-memory storage and a fake clock.
private struct Harness {
    let worker = FakeWorker(entries: ["welcome": "Hello", "max_items": "10"])
    let storage: InMemoryConfigStorage
    let clock = FakeClock()

    init(storage: InMemoryConfigStorage = InMemoryConfigStorage()) {
        self.storage = storage
    }

    func create(
        transport: (any HTTPTransport)? = nil,
        storage: (any ConfigStorage)? = nil,
        template: String = "default",
        clientKey: String? = nil
    ) -> CloudflareRemoteConfig {
        CloudflareRemoteConfig(
            endpoint: endpoint, template: template, clientKey: clientKey,
            transport: transport ?? worker, storage: storage ?? self.storage,
            clock: clock.function)
    }

    func ready(interval: TimeInterval = 0) async -> CloudflareRemoteConfig {
        let rc = create()
        await rc.ensureInitialized()
        await rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval: interval))
        return rc
    }
}

@Suite("CloudflareRemoteConfig")
struct CloudflareRemoteConfigTests {
    @Suite("initial state")
    struct InitialState {
        private let h = Harness()

        @Test("before any fetch")
        func beforeAnyFetch() async {
            let rc = await h.ready()
            #expect(rc.lastFetchStatus == .noFetchYet)
            #expect(rc.lastFetchTime == nil)
            #expect(rc.allValues().isEmpty)
            #expect(rc.configValue(forKey: "missing") == RemoteConfigValue(nil, source: .static))
            #expect(rc.configSettings == RemoteConfigSettings(minimumFetchInterval: 0))
        }

        // The initializer traps on these (see PreconditionTests); this checks
        // the validator it relies on.
        @Test("rejects invalid template names", arguments: ["", "a/b", String(repeating: "x", count: 65)])
        func rejectsTemplates(_ template: String) {
            #expect(throws: WorkerClient.InvalidArgument.self) {
                try WorkerClient.configURL(endpoint: endpoint, template: template)
            }
        }
    }

    @Suite("defaults")
    struct Defaults {
        private let h = Harness()

        @Test("are used until a remote value is activated")
        func used() async throws {
            let rc = await h.ready()
            rc.setDefaults([
                "welcome": "Default",
                "max_items": 5,
                "ratio": 0.5,
                "dark": true,
                "json": ["a": 1] as JSONValue,
                "list": [1, 2] as JSONValue,
                "ignored": String?.none,
            ])
            #expect(rc["welcome"].stringValue == "Default")
            #expect(rc["max_items"].intValue == 5)
            #expect(rc["ratio"].doubleValue == 0.5)
            #expect(rc["dark"].boolValue)
            #expect(rc["json"].stringValue == #"{"a":1}"#)
            #expect(rc["list"].stringValue == "[1,2]")
            #expect(rc["ignored"].source == .static)
            #expect(rc["welcome"].source == .default)

            try await rc.fetchAndActivate()
            #expect(rc["welcome"] == RemoteConfigValue("Hello", source: .remote))
            #expect(rc["dark"].source == .default)
        }

        // Dart throws an ArgumentError at run time; Swift rejects unsupported
        // types at compile time.
        @Test("unsupported types throw")
        func unsupportedTypes() {
            #expect(!((Date() as Any) is any RemoteConfigDefaultConvertible))
            #expect(!(([1, 2] as Any) is any RemoteConfigDefaultConvertible))
            #expect(!((["a": 1] as Any) is any RemoteConfigDefaultConvertible))
            #expect(((["a": 1] as JSONValue) as Any) is any RemoteConfigDefaultConvertible)
        }

        @Test("setDefaults replaces previous defaults")
        func replaces() async {
            let rc = await h.ready()
            rc.setDefaults(["a": "1"])
            rc.setDefaults(["b": "2"])
            #expect(rc["a"].source == .static)
            #expect(rc["b"].stringValue == "2")
        }

        // Swift-only.
        @Test("values are converted to text like the Flutter SDK does")
        func conversions() async {
            enum Theme: String, RemoteConfigDefaultConvertible { case dark }
            enum Level: Int, RemoteConfigDefaultConvertible { case high = 3 }
            let rc = await h.ready()
            rc.setDefaults([
                "double": 0.0,
                "float": Float(0.1),
                "int8": Int8(-8),
                "uint64": UInt64.max,
                "int64": Int64.min,
                "false": false,
                "optional": Optional("x"),
                "theme": Theme.dark,
                "level": Level.high,
                "null": JSONValue.null,
                "nested": ["b": [1, "two", nil], "a": "/x"] as JSONValue,
            ])
            #expect(rc["double"].stringValue == "0.0")
            #expect(rc["float"].stringValue == "0.1")
            #expect(rc["int8"].stringValue == "-8")
            #expect(rc["uint64"].stringValue == "18446744073709551615")
            #expect(rc["int64"].stringValue == "-9223372036854775808")
            #expect(rc["false"].stringValue == "false")
            #expect(rc["optional"].stringValue == "x")
            #expect(rc["theme"].stringValue == "dark")
            #expect(rc["level"].intValue == 3)
            #expect(rc["null"].source == .static)
            #expect(rc["nested"].stringValue == #"{"a":"/x","b":[1,"two",null]}"#)
            #expect(rc.allKeys(from: .default).count == 10)
        }
    }

    @Suite("fetch & activate")
    struct FetchAndActivate {
        private let h = Harness()

        @Test("fetch does not change active values until activate")
        func fetchThenActivate() async throws {
            let rc = await h.ready()
            rc.setDefaults(["welcome": "Default"])
            try await rc.fetch()
            #expect(rc.lastFetchStatus == .success)
            #expect(rc.lastFetchTime == h.clock.now)
            #expect(rc["welcome"].stringValue == "Default")

            #expect(await rc.activate())
            #expect(rc["welcome"].stringValue == "Hello")
            #expect(rc["welcome"].source == .remote)
            #expect(rc["max_items"].intValue == 10)
        }

        @Test("activate returns false when nothing new")
        func nothingNew() async throws {
            let rc = await h.ready()
            #expect(await rc.activate() == false)
            #expect(try await rc.fetchAndActivate())
            #expect(await rc.activate() == false)
            // Unchanged remote config -> 304 -> nothing to activate.
            #expect(try await rc.fetchAndActivate() == false)
            #expect(h.worker.requests.last?.value(forHTTPHeaderField: "If-None-Match") != nil)
        }

        @Test("changed remote config is picked up via a new fetch")
        func changedConfig() async throws {
            let rc = await h.ready()
            try await rc.fetchAndActivate()
            h.worker.entries = ["welcome": "Updated"]
            #expect(try await rc.fetchAndActivate())
            #expect(rc["welcome"].stringValue == "Updated")
            // Keys removed remotely fall back to defaults/static.
            #expect(rc["max_items"].source == .static)
        }

        @Test("remote rollback to the active config discards pending fetch")
        func rollback() async throws {
            let rc = await h.ready()
            try await rc.fetchAndActivate() // active = A
            let original = h.worker.entries
            h.worker.entries = ["welcome": "B"]
            try await rc.fetch() // pending = B
            h.worker.entries = original
            try await rc.fetch() // server back to A
            #expect(await rc.activate() == false)
            #expect(rc["welcome"].stringValue == "Hello")
        }

        @Test("empty remote config with nothing active -> nothing to activate")
        func emptyConfig() async throws {
            h.worker.entries = [:]
            let rc = await h.ready()
            #expect(try await rc.fetchAndActivate() == false)
            #expect(rc.lastFetchStatus == .success)
        }

        @Test("getAll merges defaults and remote values")
        func allValues() async throws {
            let rc = await h.ready()
            rc.setDefaults(["welcome": "Default", "only_default": "x"])
            try await rc.fetchAndActivate()
            let all = rc.allValues()
            #expect(Set(all.keys) == ["welcome", "max_items", "only_default"])
            #expect(all["welcome"] == RemoteConfigValue("Hello", source: .remote))
            #expect(all["only_default"]?.source == .default)
        }

        @Test("client key is sent")
        func clientKey() async throws {
            h.worker.clientKey = "k"
            let rc = h.create(clientKey: "k")
            await rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval: 0))
            #expect(try await rc.fetchAndActivate())
        }

        // Swift-only.
        @Test("values by source, and sorted keys")
        func bySource() async throws {
            let rc = await h.ready()
            rc.setDefaults(["welcome": "Default", "z_default": "z"])
            try await rc.fetchAndActivate()
            #expect(rc.configValue(forKey: "welcome", source: .remote) == RemoteConfigValue("Hello", source: .remote))
            #expect(rc.configValue(forKey: "welcome", source: .default) == RemoteConfigValue("Default", source: .default))
            #expect(rc.configValue(forKey: "welcome", source: .static) == RemoteConfigValue(nil, source: .static))
            #expect(rc.configValue(forKey: "z_default", source: .remote) == RemoteConfigValue(nil, source: .static))
            #expect(rc.allKeys(from: .remote) == ["max_items", "welcome"])
            #expect(rc.allKeys(from: .default) == ["welcome", "z_default"])
            #expect(rc.allKeys(from: .static).isEmpty)
        }
    }

    @Suite("minimumFetchInterval")
    struct MinimumFetchInterval {
        private let h = Harness()

        @Test("skips the network inside the interval")
        func skips() async throws {
            let rc = await h.ready(interval: 3_600)
            try await rc.fetch()
            #expect(h.worker.requests.count == 1)

            h.clock.advance(by: 59 * 60)
            try await rc.fetch()
            #expect(h.worker.requests.count == 1)

            h.clock.advance(by: 60)
            try await rc.fetch()
            #expect(h.worker.requests.count == 2)
        }

        @Test("failed fetches do not start the interval")
        func failures() async throws {
            let rc = await h.ready(interval: 3_600)
            h.worker.override = { _ in HTTPResponse(500) }
            await expectError(code: .serverError) { try await rc.fetch() }
            h.worker.override = nil
            try await rc.fetch()
            #expect(h.worker.requests.count == 2)
        }

        @Test("clock moving backwards does not block fetching")
        func clockBackwards() async throws {
            let rc = await h.ready(interval: 3_600)
            try await rc.fetch()
            h.clock.advance(by: -2 * 3_600)
            try await rc.fetch()
            #expect(h.worker.requests.count == 2)
        }
    }

    enum FailureCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case http500 = "500"
        case http401 = "401"
        case badJSON = "bad json"
        case network

        var testDescription: String { rawValue }

        var override: FakeWorker.Handler {
            switch self {
            case .http500: return { _ in HTTPResponse(500, #"{"error":"invalid_config"}"#) }
            case .http401: return { _ in HTTPResponse(401) }
            case .badJSON: return { _ in HTTPResponse(200, "oops") }
            case .network: return { _ in throw URLError(.notConnectedToInternet) }
            }
        }

        var code: RemoteConfigError.Code {
            switch self {
            case .http500: return .serverError
            case .http401: return .unauthorized
            case .badJSON: return .invalidResponse
            case .network: return .networkError
            }
        }
    }

    @Suite("failures")
    struct Failures {
        private let h = Harness()

        @Test("-> failure status, active config untouched", arguments: FailureCase.allCases)
        func failure(_ failure: FailureCase) async throws {
            let rc = await h.ready()
            try await rc.fetchAndActivate()
            let fetchTime = rc.lastFetchTime
            h.clock.advance(by: 60)

            h.worker.override = failure.override
            await expectError(code: failure.code) { try await rc.fetchAndActivate() }
            #expect(rc.lastFetchStatus == .failure)
            #expect(rc.lastFetchTime == fetchTime)
            #expect(rc["welcome"].stringValue == "Hello")
        }

        @Test("timeout -> failure")
        func timeout() async {
            let rc = h.create(transport: StubTransport.neverResponds)
            await rc.setConfigSettings(RemoteConfigSettings(fetchTimeout: 0.02, minimumFetchInterval: 0))
            await expectError(code: .timeout) { try await rc.fetch() }
            #expect(rc.lastFetchStatus == .failure)
        }
    }

    @Suite("throttling")
    struct Throttling {
        private let h = Harness()

        @Test("429 sets throttle and blocks fetches until it ends")
        func throttle() async throws {
            let rc = await h.ready()
            h.worker.override = { _ in HTTPResponse(429, headers: ["retry-after": "30"]) }
            await expectError(code: .throttled) { try await rc.fetch() }
            #expect(rc.lastFetchStatus == .throttled)
            #expect(h.worker.requests.count == 1)

            h.worker.override = nil
            h.clock.advance(by: 29)
            await expectError(code: .throttled, throttleEnd: h.clock.now.addingTimeInterval(1)) {
                try await rc.fetch()
            }
            #expect(h.worker.requests.count == 1, "no network while throttled")

            h.clock.advance(by: 1)
            try await rc.fetch()
            #expect(rc.lastFetchStatus == .success)
            #expect(h.worker.requests.count == 2)
        }
    }

    // The gated tests would hang, rather than fail, if requests were not
    // shared, hence the time limits.
    @Suite("concurrency")
    struct Concurrency {
        private let h = Harness()

        @available(macOS 13, iOS 16, tvOS 16, watchOS 9, visionOS 1, *)
        @Test("concurrent fetches share one request", .timeLimit(.minutes(1)))
        func shareOneRequest() async throws {
            let entered = AsyncGate()
            let release = AsyncGate()
            let calls = Recorder<URLRequest>()
            let worker = h.worker
            let rc = h.create(transport: StubTransport { request in
                calls.record(request)
                await entered.open()
                await release.wait()
                return try await worker.handle(request)
            })
            await rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval: 0))

            let activated = Task { try await rc.fetchAndActivate() }
            await entered.wait() // The request is in flight, held by the gate.
            let a = rc.startFetch()
            let b = rc.startFetch()
            #expect(a == b)
            await release.open()
            try await a.value
            try await b.value
            #expect(try await activated.value)
            #expect(calls.count == 1)

            try await rc.fetch() // a new fetch after completion hits the network again
            #expect(calls.count == 2)
        }

        @available(macOS 13, iOS 16, tvOS 16, watchOS 9, visionOS 1, *)
        @Test("concurrent failing fetches all throw", .timeLimit(.minutes(1)))
        func failingFetches() async {
            let rc = await h.ready()
            let release = AsyncGate()
            h.worker.override = { _ in
                await release.wait()
                return HTTPResponse(500)
            }
            let a = rc.startFetch()
            let b = rc.startFetch()
            await release.open()
            await expectError(code: .serverError) { try await a.value }
            await expectError(code: .serverError) { try await b.value }
            #expect(h.worker.requests.count == 1)
        }

        // Swift-only.
        @available(macOS 13, iOS 16, tvOS 16, watchOS 9, visionOS 1, *)
        @Test("a cancelled caller does not cancel the shared fetch", .timeLimit(.minutes(1)))
        func cancelledCaller() async throws {
            let entered = AsyncGate()
            let release = AsyncGate()
            let worker = h.worker
            let rc = h.create(transport: StubTransport { request in
                await entered.open()
                await release.wait()
                return try await worker.handle(request)
            })
            await rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval: 0))

            let caller = Task { try await rc.fetch() }
            await entered.wait()
            caller.cancel()
            await release.open()
            try await caller.value
            #expect(rc.lastFetchStatus == .success)
            #expect(await rc.activate())
            #expect(h.worker.requests.count == 1)
        }
    }

    @Suite("persistence")
    struct Persistence {
        private let h = Harness()

        @Test("active, pending, settings and status survive restarts")
        func surviveRestarts() async throws {
            let rc1 = await h.ready(interval: 3_600)
            try await rc1.fetchAndActivate()
            h.worker.entries = ["welcome": "Pending"]
            h.clock.advance(by: 3_600)
            try await rc1.fetch()

            let rc2 = h.create()
            await rc2.ensureInitialized()
            #expect(rc2["welcome"].stringValue == "Hello")
            #expect(rc2.configSettings.minimumFetchInterval == 3_600)
            #expect(rc2.lastFetchStatus == .success)
            #expect(rc2.lastFetchTime == h.clock.now)

            // Pending config from rc1 can be activated after restart.
            #expect(await rc2.activate())
            #expect(rc2["welcome"].stringValue == "Pending")

            // minimumFetchInterval is honoured across restarts.
            try await rc2.fetch()
            #expect(h.worker.requests.count == 2)
        }

        @Test("ETag survives restarts")
        func etagSurvives() async throws {
            let rc1 = await h.ready()
            try await rc1.fetchAndActivate()
            let rc2 = h.create()
            try await rc2.fetch()
            #expect(h.worker.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"\(h.worker.version)\"")
        }

        @Test("templates and endpoints are stored separately")
        func separateKeys() async throws {
            let rc1 = await h.ready()
            try await rc1.fetchAndActivate()
            let other = h.create(template: "staging")
            await other.ensureInitialized()
            #expect(other["welcome"].source == .static)
            await other.setConfigSettings(RemoteConfigSettings())
            #expect(Set(await h.storage.data.keys) == [
                "cloudflare_worker_kv:https://cfg.example.com|default",
                "cloudflare_worker_kv:https://cfg.example.com|staging",
            ])
            #expect(rc1.configSettings.minimumFetchInterval == 0)
        }

        @Test("corrupt cache is ignored", arguments: [
            "not json",
            "[]",
            #"{"formatVersion":99}"#,
            #"{"formatVersion":1,"active":{"entries":"nope"}}"#,
        ])
        func corruptCache(_ corrupt: String) async throws {
            let h = Harness(storage: InMemoryConfigStorage([defaultKey: corrupt]))
            let rc = h.create()
            await rc.ensureInitialized()
            #expect(rc.allValues().isEmpty)
            #expect(rc.lastFetchStatus == .noFetchYet)
            #expect(rc.configSettings == RemoteConfigSettings())
            await rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval: 0))
            #expect(try await rc.fetchAndActivate())
        }

        @Test("storage failures never break fetch/activate")
        func storageFailures() async throws {
            let rc = h.create(storage: ThrowingStorage())
            await rc.ensureInitialized()
            await rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval: 0))
            #expect(try await rc.fetchAndActivate())
            #expect(rc["welcome"].stringValue == "Hello")
        }

        @Test("last write wins when writes overlap")
        func lastWriteWins() async throws {
            let slow = SlowStorage()
            let rc2 = h.create(storage: slow)
            await rc2.ensureInitialized()
            await rc2.setConfigSettings(RemoteConfigSettings(minimumFetchInterval: 0))
            try await rc2.fetch()
            await slow.resetDelays()

            // Two persists in flight at once; the first is the slowest.
            let newSettings = RemoteConfigSettings(minimumFetchInterval: 5 * 60)
            async let activated = rc2.activate()
            async let updated: Void = rc2.setConfigSettings(newSettings)
            _ = await (activated, updated)

            let stored = await slow.data
            #expect(stored.count == 1)
            let saved = try JSONValue(parsing: Data(try #require(stored.values.first).utf8))
            #expect(saved["active"] != nil && saved["active"] != .null)
            #expect(saved["fetched"] == .null)
            #expect(RemoteConfigSettings(validatingMs: saved["settings"]) == newSettings)
        }

        // Swift-only.
        @Test("writes the cache format shared with the other SDKs")
        func writesSharedFormat() async throws {
            let rc = await h.ready()
            try await rc.fetchAndActivate()
            let raw = try #require(await h.storage.data[defaultKey])
            let expected: JSONValue = [
                "formatVersion": 1,
                "active": [
                    "version": .string(h.worker.version),
                    "entries": ["welcome": "Hello", "max_items": "10"],
                ],
                "fetched": nil,
                "etag": .string("\"\(h.worker.version)\""),
                "lastSuccessfulFetchMs": 1_767_225_600_000,
                "throttleEndMs": nil,
                "lastFetchStatus": "success",
                "settings": ["fetchTimeoutMs": 60_000, "minimumFetchIntervalMs": 0],
            ]
            #expect(try JSONValue(parsing: Data(raw.utf8)) == expected)
        }

        // Swift-only.
        @Test("reads a cache written by the Flutter SDK")
        func readsFlutterCache() async throws {
            let flutter = #"{"formatVersion":1,"active":{"version":"v1","entries":{"welcome":"From Flutter"}},"# +
                #""fetched":{"version":"v2","entries":{"welcome":"Pending"}},"etag":"\"v1\"","# +
                #""lastSuccessfulFetchMs":1767225600000,"throttleEndMs":null,"lastFetchStatus":"throttle","# +
                #""settings":{"fetchTimeoutMs":10000,"minimumFetchIntervalMs":3600000}}"#
            let h = Harness(storage: InMemoryConfigStorage([defaultKey: flutter]))
            let rc = h.create()
            await rc.ensureInitialized()
            #expect(rc["welcome"] == RemoteConfigValue("From Flutter", source: .remote))
            #expect(rc.lastFetchTime == FakeClock.start)
            #expect(rc.lastFetchStatus == .throttled)
            #expect(rc.configSettings == RemoteConfigSettings(fetchTimeout: 10, minimumFetchInterval: 3_600))
            #expect(await rc.activate())
            #expect(rc["welcome"].stringValue == "Pending")

            h.clock.advance(by: 3_600)
            try await rc.fetch()
            #expect(h.worker.requests.last?.value(forHTTPHeaderField: "If-None-Match") == #""v1""#)
        }

        // Swift-only.
        @Test("invalid fields fall back to their defaults")
        func invalidFields() async {
            let cache = #"{"formatVersion":1,"active":{"version":7,"entries":{"k":"v","n":1}},"etag":5,"# +
                #""lastSuccessfulFetchMs":"x","throttleEndMs":1.5,"lastFetchStatus":"bogus","# +
                #""settings":{"fetchTimeoutMs":0,"minimumFetchIntervalMs":1}}"#
            let h = Harness(storage: InMemoryConfigStorage([defaultKey: cache]))
            let rc = h.create()
            await rc.ensureInitialized()
            #expect(rc["k"] == RemoteConfigValue("v", source: .remote))
            #expect(rc["n"].stringValue == "1")
            #expect(rc.lastFetchTime == nil)
            #expect(rc.lastFetchStatus == .noFetchYet)
            #expect(rc.configSettings == RemoteConfigSettings())
        }
    }

    @Suite("singleton", .serialized)
    struct Singleton {
        private let h = Harness()

        init() {
            CloudflareRemoteConfig.resetShared()
        }

        // Accessing `shared` here would trap; see PreconditionTests.
        @Test("instance throws before initialize")
        func beforeInitialize() {
            #expect(CloudflareRemoteConfig.sharedIfInitialized == nil)
        }

        @Test("initialize loads cache and exposes instance")
        func initialize() async throws {
            let rc1 = await h.ready()
            try await rc1.fetchAndActivate()

            let rc = await CloudflareRemoteConfig.initialize(
                endpoint: endpoint, transport: h.worker, storage: h.storage, clock: h.clock.function)
            #expect(CloudflareRemoteConfig.shared === rc)
            #expect(rc["welcome"].stringValue == "Hello") // no await needed
            CloudflareRemoteConfig.resetShared()
        }

        // Swift-only.
        @Test("initialize again replaces the shared instance")
        func replaces() async {
            let first = await CloudflareRemoteConfig.initialize(
                endpoint: endpoint, transport: h.worker, storage: h.storage)
            let second = await CloudflareRemoteConfig.initialize(
                endpoint: endpoint, template: "staging", transport: h.worker, storage: h.storage)
            #expect(first !== second)
            #expect(CloudflareRemoteConfig.shared === second)
            CloudflareRemoteConfig.resetShared()
        }
    }
}
