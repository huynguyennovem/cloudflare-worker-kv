import Foundation
import Testing
@testable import CloudflareWorkerKV

// The real URLSession transport, through the public initializer, against
// StubURLProtocol. Serialized because the stub's handler is global.
@Suite("URLSessionTransport", .serialized)
struct URLSessionTransportTests {
    private let session = StubURLProtocol.makeSession()

    private func create(clientKey: String? = nil) -> CloudflareRemoteConfig {
        CloudflareRemoteConfig(
            endpoint: URL(string: "https://cfg.example.com/edge/")!,
            template: "staging",
            clientKey: clientKey,
            session: session,
            storage: InMemoryConfigStorage())
    }

    @Test("sends a GET with the URL and headers of the contract")
    func request() async throws {
        StubURLProtocol.reset { _ in
            .response(status: 200, headers: ["ETag": #"W/"v1""#, "Content-Type": "application/json"],
                      body: Data(#"{"version":"v1","entries":{"a":"xin chào"}}"#.utf8))
        }
        let rc = create(clientKey: "k3y")
        await rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval: 0))
        #expect(try await rc.fetchAndActivate())
        #expect(rc["a"].stringValue == "xin chào")

        let request = try #require(StubURLProtocol.requests.last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://cfg.example.com/edge/v1/config?template=staging")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Client-Key") == "k3y")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("the second fetch sends If-None-Match verbatim, and a 304 activates nothing")
    func conditionalRequest() async throws {
        StubURLProtocol.reset { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == #"W/"v1""# {
                return .response(status: 304, headers: ["ETag": #"W/"v1""#], body: Data())
            }
            return .response(status: 200, headers: ["ETag": #"W/"v1""#],
                             body: Data(#"{"version":"v1","entries":{"a":"1"}}"#.utf8))
        }
        let rc = create()
        await rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval: 0))
        #expect(try await rc.fetchAndActivate())
        #expect(try await rc.fetchAndActivate() == false)
        #expect(rc.lastFetchStatus == .success)
        #expect(rc["a"].stringValue == "1")

        let requests = StubURLProtocol.requests
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "If-None-Match") == #"W/"v1""#)
        #expect(requests.first?.value(forHTTPHeaderField: "X-Client-Key") == nil)
    }

    @Test("an offline device -> network-error")
    func offline() async {
        StubURLProtocol.reset { _ in .failure(URLError(.notConnectedToInternet)) }
        let rc = create()
        let error = await expectError(code: .networkError) { try await rc.fetch() }
        #expect((error?.underlyingError as? URLError)?.code == .notConnectedToInternet)
        #expect(rc.lastFetchStatus == .failure)
    }

    @Test("URLError.timedOut -> timeout")
    func urlTimeout() async {
        StubURLProtocol.reset { _ in .failure(URLError(.timedOut)) }
        let rc = create()
        await expectError(code: .timeout) { try await rc.fetch() }
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, visionOS 1, *)
    @Test("a server that never responds -> timeout after fetchTimeout", .timeLimit(.minutes(1)))
    func neverResponds() async {
        StubURLProtocol.reset { _ in .never }
        let rc = create()
        await rc.setConfigSettings(RemoteConfigSettings(fetchTimeout: 0.1, minimumFetchInterval: 0))
        let started = Date()
        let error = await expectError(code: .timeout) { try await rc.fetch() }
        #expect(error?.message == "No response within 100 ms.")
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("an HTTP error status is mapped with its body")
    func httpError() async {
        StubURLProtocol.reset { _ in
            .response(status: 503, headers: [:],
                      body: Data(#"{"error":"kv_unavailable","message":"Failed to read config from KV."}"#.utf8))
        }
        let rc = create()
        await expectError(code: .serverError, statusCode: 503, messageContains: "kv_unavailable") {
            try await rc.fetch()
        }
    }
}
