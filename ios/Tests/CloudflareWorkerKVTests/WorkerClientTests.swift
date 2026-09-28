import Foundation
import Testing
@testable import CloudflareWorkerKV

private func build(_ endpoint: String, _ template: String) throws -> String {
    try WorkerClient.configURL(endpoint: URL(string: endpoint)!, template: template).absoluteString
}

// Port of flutter/test/worker_client_test.dart.
@Suite("WorkerClient")
struct WorkerClientTests {
    static let endpoint = URL(string: "https://cfg.example.com")!
    static let now = FakeClock.start
    static let timeout: TimeInterval = 5

    static func client(clientKey: String? = nil,
                       _ handler: @escaping @Sendable (URLRequest) async throws -> HTTPResponse) -> WorkerClient {
        WorkerClient(
            configURL: try! WorkerClient.configURL(endpoint: endpoint, template: "default"),
            clientKey: clientKey,
            transport: StubTransport(handler),
            clock: { now })
    }

    @Suite("buildConfigUri")
    struct BuildConfigURI {
        @Test("appends path and template")
        func appends() throws {
            #expect(try build("https://a.dev", "default") == "https://a.dev/v1/config?template=default")
        }

        @Test("preserves path prefix, query and drops fragment")
        func preserves() throws {
            #expect(try build("https://a.dev/api/?x=1#frag", "staging")
                == "https://a.dev/api/v1/config?x=1&template=staging")
        }

        @Test("keeps a custom port")
        func port() throws {
            #expect(try build("https://config.example.com:8443", "d")
                == "https://config.example.com:8443/v1/config?template=d")
        }

        @Test("rejects relative URLs")
        func rejectsRelative() {
            #expect(throws: WorkerClient.InvalidArgument.self) { try build("/config", "d") }
        }

        // Swift-specific cases.

        @Test("replaces a repeated template parameter once, in place")
        func repeatedTemplate() throws {
            #expect(try build("https://a.dev/?template=a&x=1&template=b", "c")
                == "https://a.dev/v1/config?template=c&x=1")
        }

        @Test("keeps the rest of the query verbatim")
        func verbatimQuery() throws {
            #expect(try build("https://a.dev/?q=a%20b&flag", "d")
                == "https://a.dev/v1/config?q=a%20b&flag&template=d")
        }

        @Test("resolves a URL relative to a base URL")
        func relativeToBase() throws {
            let endpoint = URL(string: "api/", relativeTo: URL(string: "https://a.dev/")!)!
            #expect(try WorkerClient.configURL(endpoint: endpoint, template: "d").absoluteString
                == "https://a.dev/api/v1/config?template=d")
        }

        @Test("rejects invalid templates", arguments: ["", "a/b", "a b", "é", String(repeating: "x", count: 65)])
        func rejectsTemplate(_ template: String) {
            #expect(throws: WorkerClient.InvalidArgument.self) {
                try WorkerClient.validateTemplate(template)
            }
            #expect(throws: WorkerClient.InvalidArgument.self) {
                try WorkerClient.configURL(endpoint: WorkerClientTests.endpoint, template: template)
            }
        }

        @Test("accepts valid templates", arguments: ["d", "A-b_9", String(repeating: "x", count: 64)])
        func acceptsTemplate(_ template: String) throws {
            try WorkerClient.validateTemplate(template)
        }
    }

    @Test("sends headers and parses 200")
    func sendsHeaders() async throws {
        let seen = Recorder<URLRequest>()
        let client = Self.client(clientKey: "secret") { request in
            seen.record(request)
            let body: JSONValue = [
                "version": "v1",
                "entries": ["a": "xin chào", "n": 1, "b": true, "o": ["k": 1], "z": nil],
            ]
            return HTTPResponse(200, body.compactJSONString, headers: ["ETag": #""v1""#])
        }

        let result = try await client.fetch(etag: #""v0""#, timeout: Self.timeout)

        let request = try #require(seen.last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://cfg.example.com/v1/config?template=default")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-Client-Key") == "secret")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == #""v0""#)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == Self.timeout)
        #expect(result == .fetched(
            ConfigSnapshot(version: "v1", entries: ["a": "xin chào", "n": "1", "b": "true", "o": #"{"k":1}"#]),
            etag: #""v1""#))
    }

    @Test("omits optional headers when not provided")
    func omitsHeaders() async throws {
        let seen = Recorder<URLRequest>()
        let client = Self.client { request in
            seen.record(request)
            return HTTPResponse(200, #"{"version":"v","entries":{}}"#)
        }
        _ = try await client.fetch(etag: nil, timeout: Self.timeout)
        let request = try #require(seen.last)
        #expect(request.value(forHTTPHeaderField: "X-Client-Key") == nil)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("falls back to ETag when version is missing")
    func etagFallback() async throws {
        let client = Self.client { _ in
            HTTPResponse(200, #"{"entries":{}}"#, headers: ["etag": #"W/"abc""#])
        }
        let result = try await client.fetch(etag: nil, timeout: Self.timeout)
        #expect(result == .fetched(ConfigSnapshot(version: "abc", entries: [:]), etag: #"W/"abc""#))
    }

    @Test("304 with etag -> not modified")
    func notModified() async throws {
        let client = Self.client { _ in HTTPResponse(304) }
        #expect(try await client.fetch(etag: #""v""#, timeout: Self.timeout) == .notModified)
    }

    @Test("304 without etag -> invalid-response")
    func unconditional304() async {
        let client = Self.client { _ in HTTPResponse(304) }
        await expectError(code: .invalidResponse, statusCode: 304) {
            try await client.fetch(etag: nil, timeout: Self.timeout)
        }
    }

    @Test("malformed bodies -> invalid-response",
          arguments: ["not json", "[]", #"{"entries":[]}"#, "{}", "null"])
    func malformed(_ body: String) async {
        let client = Self.client { _ in HTTPResponse(200, body) }
        await expectError(code: .invalidResponse, statusCode: 200) {
            try await client.fetch(etag: nil, timeout: Self.timeout)
        }
    }

    @Test("401 and 403 -> unauthorized", arguments: [401, 403])
    func unauthorized(_ status: Int) async {
        let client = Self.client { _ in HTTPResponse(status) }
        await expectError(code: .unauthorized, statusCode: status) {
            try await client.fetch(etag: nil, timeout: Self.timeout)
        }
    }

    @Test("429 -> throttled with Retry-After")
    func throttled() async {
        let client = Self.client { _ in HTTPResponse(429, headers: ["retry-after": "120"]) }
        await expectError(code: .throttled, statusCode: 429, throttleEnd: Self.now.addingTimeInterval(120)) {
            try await client.fetch(etag: nil, timeout: Self.timeout)
        }
    }

    @Test("429 without Retry-After uses default duration")
    func throttledDefault() async {
        let client = Self.client { _ in HTTPResponse(429) }
        await expectError(code: .throttled,
                          throttleEnd: Self.now.addingTimeInterval(WorkerClient.defaultThrottleDuration)) {
            try await client.fetch(etag: nil, timeout: Self.timeout)
        }
    }

    @Test("5xx -> server-error with worker error code in message")
    func serverError() async {
        let client = Self.client { _ in HTTPResponse(500, #"{"error":"invalid_config","message":"bad"}"#) }
        let error = await expectError(code: .serverError, statusCode: 500, messageContains: "invalid_config") {
            try await client.fetch(etag: nil, timeout: Self.timeout)
        }
        #expect(error?.message == "Unexpected response: invalid_config - bad")
    }

    @Test("network error -> network-error")
    func networkError() async {
        let client = Self.client { _ in throw URLError(.notConnectedToInternet) }
        let error = await expectError(code: .networkError) {
            try await client.fetch(etag: nil, timeout: Self.timeout)
        }
        #expect(error?.statusCode == nil)
        #expect((error?.underlyingError as? URLError)?.code == .notConnectedToInternet)
    }

    @Test("slow response -> timeout")
    func timeout() async {
        let client = WorkerClient(
            configURL: try! WorkerClient.configURL(endpoint: Self.endpoint, template: "default"),
            clientKey: nil, transport: StubTransport.neverResponds, clock: { Self.now })
        let error = await expectError(code: .timeout) {
            try await client.fetch(etag: nil, timeout: 0.02)
        }
        #expect(error?.message == "No response within 20 ms.")
    }

    @Test("exception toString is informative")
    func description() {
        let error = RemoteConfigError(code: .serverError, message: "boom", statusCode: 502)
        #expect(error.description == "RemoteConfigError[server-error] (HTTP 502): boom")
        #expect(error.localizedDescription == "RemoteConfigError[server-error] (HTTP 502): boom")
        #expect(RemoteConfigError(code: .timeout, message: "slow").description
            == "RemoteConfigError[timeout]: slow")
    }

    // Swift-specific cases.

    @Test("error codes use the shared strings")
    func codes() {
        #expect(RemoteConfigError.Code.allCases.map(\.rawValue) == [
            "timeout", "network-error", "unauthorized", "throttled", "server-error", "invalid-response",
        ])
    }

    @Test("a 5xx without a JSON body uses the reason phrase")
    func reasonPhrase() async {
        let client = Self.client { _ in HTTPResponse(502, "<html>Bad gateway</html>") }
        let error = await expectError(code: .serverError, statusCode: 502) {
            try await client.fetch(etag: nil, timeout: Self.timeout)
        }
        #expect(error?.message == "Unexpected response: \(HTTPURLResponse.localizedString(forStatusCode: 502))")
    }

    @Test("URLError.timedOut -> timeout")
    func urlTimeout() async {
        let client = Self.client { _ in throw URLError(.timedOut) }
        await expectError(code: .timeout) {
            try await client.fetch(etag: nil, timeout: Self.timeout)
        }
    }

    @Test("stripETag", arguments: [
        (#""v1""#, "v1"), (#"W/"abc""#, "abc"), (#" "x" "#, "x"), ("plain", "plain"), (#"""#, #"""#),
        (#""""#, ""), (#""xin chào""#, "xin chào"),
    ])
    func stripETag(_ input: String, _ expected: String) {
        #expect(WorkerClient.stripETag(input) == expected)
    }
}
