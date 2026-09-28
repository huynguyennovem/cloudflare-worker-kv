// Invalid arguments are programming errors and trip a precondition, like the
// Flutter SDK's ArgumentError. Exit tests run each case in a child process;
// they are only available on macOS, from Swift 6.2.
#if os(macOS) && compiler(>=6.2)
import Foundation
import Testing
@testable import CloudflareWorkerKV

@Suite("Preconditions")
struct PreconditionTests {
    @Test("a relative endpoint traps")
    func relativeEndpoint() async {
        await #expect(processExitsWith: .failure) {
            _ = CloudflareRemoteConfig(endpoint: URL(string: "/config")!, storage: InMemoryConfigStorage())
        }
    }

    @Test("an endpoint without a host traps")
    func endpointWithoutHost() async {
        await #expect(processExitsWith: .failure) {
            _ = CloudflareRemoteConfig(endpoint: URL(string: "mailto:someone@example.com")!,
                                       storage: InMemoryConfigStorage())
        }
    }

    @Test("an invalid template traps")
    func invalidTemplate() async {
        await #expect(processExitsWith: .failure) {
            _ = CloudflareRemoteConfig(endpoint: URL(string: "https://a.dev")!, template: "a/b",
                                       storage: InMemoryConfigStorage())
        }
    }

    @Test("a zero fetchTimeout traps")
    func zeroTimeout() async {
        await #expect(processExitsWith: .failure) {
            _ = RemoteConfigSettings(fetchTimeout: 0)
        }
    }

    @Test("a negative minimumFetchInterval traps")
    func negativeInterval() async {
        await #expect(processExitsWith: .failure) {
            _ = RemoteConfigSettings(minimumFetchInterval: -1)
        }
    }

    @Test("a non-finite setting traps")
    func nonFinite() async {
        await #expect(processExitsWith: .failure) {
            _ = RemoteConfigSettings(fetchTimeout: .nan)
        }
        await #expect(processExitsWith: .failure) {
            _ = RemoteConfigSettings(minimumFetchInterval: .infinity)
        }
    }

    @Test("shared traps before initialize")
    func sharedBeforeInitialize() async {
        await #expect(processExitsWith: .failure) {
            _ = CloudflareRemoteConfig.shared
        }
    }
}
#endif
