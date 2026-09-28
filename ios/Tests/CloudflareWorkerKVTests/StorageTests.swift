import Foundation
import Testing
@testable import CloudflareWorkerKV

/// A `UserDefaults` suite unique to one test, removed by ``cleanUp()``.
private struct TemporaryDefaults {
    let name = "CloudflareWorkerKVTests.\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }

    func cleanUp() {
        defaults.removePersistentDomain(forName: name)
    }
}

// Port of flutter/test/storage_test.dart.
@Suite("Storage")
struct StorageTests {
    enum Kind: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case inMemory = "InMemoryConfigStorage"
        case userDefaults = "UserDefaultsConfigStorage"
        var testDescription: String { rawValue }
    }

    @Test("read/write/delete", arguments: Kind.allCases)
    func contract(_ kind: Kind) async throws {
        let temporary = TemporaryDefaults()
        defer { temporary.cleanUp() }
        let storage: any ConfigStorage = switch kind {
        case .inMemory: InMemoryConfigStorage()
        case .userDefaults: UserDefaultsConfigStorage(userDefaults: temporary.defaults)
        }

        #expect(try await storage.value(forKey: "k") == nil)
        try await storage.setValue("v1", forKey: "k")
        #expect(try await storage.value(forKey: "k") == "v1")
        try await storage.setValue("v2", forKey: "k")
        #expect(try await storage.value(forKey: "k") == "v2")
        try await storage.removeValue(forKey: "k")
        #expect(try await storage.value(forKey: "k") == nil)
    }

    @Test("default storage persists across instances")
    func persistsAcrossInstances() async throws {
        let temporary = TemporaryDefaults()
        defer { temporary.cleanUp() }
        let worker = FakeWorker(entries: ["a": "1"])
        let endpoint = URL(string: "https://cfg.example.com")!

        let rc1 = CloudflareRemoteConfig(
            endpoint: endpoint, transport: worker,
            storage: UserDefaultsConfigStorage(userDefaults: temporary.defaults))
        await rc1.setConfigSettings(RemoteConfigSettings(minimumFetchInterval: 0))
        try await rc1.fetchAndActivate()

        let rc2 = CloudflareRemoteConfig(
            endpoint: endpoint, transport: worker,
            storage: UserDefaultsConfigStorage(userDefaults: temporary.defaults))
        await rc2.ensureInitialized()
        #expect(rc2["a"].stringValue == "1")
        #expect(temporary.defaults.string(forKey: "cloudflare_worker_kv:https://cfg.example.com|default") != nil)
    }

    // Swift-only.
    @Test("InMemoryConfigStorage starts with the initial data")
    func initialData() async {
        let storage = InMemoryConfigStorage(["k": "v"])
        #expect(await storage.data == ["k": "v"])
        #expect(await storage.value(forKey: "k") == "v")
    }
}
