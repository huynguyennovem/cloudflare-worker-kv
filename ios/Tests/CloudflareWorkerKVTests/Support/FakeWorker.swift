import Foundation
@testable import CloudflareWorkerKV

/// Simulates the config Worker's HTTP contract in memory. A port of the
/// Flutter SDK's `test/helpers/fake_worker.dart`.
final class FakeWorker: HTTPTransport, Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> HTTPResponse

    private struct State {
        var entries: [String: String]
        var clientKey: String?
        var override: Handler?
        var requests: [URLRequest] = []
    }

    private let state: Locked<State>

    init(entries: [String: String] = [:], clientKey: String? = nil) {
        state = Locked(State(entries: entries, clientKey: clientKey))
    }

    /// Current config served by the fake Worker.
    var entries: [String: String] {
        get { state.withLock { $0.entries } }
        set { state.withLock { $0.entries = newValue } }
    }

    /// When set, requests must send a matching `X-Client-Key`.
    var clientKey: String? {
        get { state.withLock { $0.clientKey } }
        set { state.withLock { $0.clientKey = newValue } }
    }

    /// When set, used instead of the normal response.
    var override: Handler? {
        get { state.withLock { $0.override } }
        set { state.withLock { $0.override = newValue } }
    }

    /// Every request received, in order.
    var requests: [URLRequest] { state.withLock { $0.requests } }

    /// base64url of `[[key, value], ...]` sorted by key, like the Dart helper.
    var version: String {
        let pairs = entries.keys.sorted().map { key -> JSONValue in
            [.string(key), .string(entries[key]!)]
        }
        return Data(JSONValue.array(pairs).compactJSONString.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await handle(request)
    }

    /// Handles one request like the real Worker would.
    func handle(_ request: URLRequest) async throws -> HTTPResponse {
        let (override, clientKey, entries) = state.withLock { state in
            state.requests.append(request)
            return (state.override, state.clientKey, state.entries)
        }
        if let override { return try await override(request) }
        if let clientKey, request.value(forHTTPHeaderField: "X-Client-Key") != clientKey {
            return HTTPResponse(401, #"{"error":"unauthorized"}"#)
        }
        let version = self.version
        let etag = "\"\(version)\""
        if request.value(forHTTPHeaderField: "If-None-Match") == etag {
            return HTTPResponse(304, headers: ["etag": etag])
        }
        let body: JSONValue = [
            "version": .string(version),
            "entries": .object(entries.mapValues(JSONValue.string)),
        ]
        return HTTPResponse(200, body.compactJSONString,
                            headers: ["etag": etag, "content-type": "application/json"])
    }
}

/// A transport that answers every request with `handler`.
struct StubTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) async throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (URLRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await handler(request)
    }

    /// Never answers; honours cancellation like a real transport.
    static let neverResponds = StubTransport { _ in
        try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
        throw URLError(.cannotConnectToHost)
    }
}

/// Records values across concurrent closures.
final class Recorder<Value: Sendable>: Sendable {
    private let values = Locked<[Value]>([])

    func record(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    var all: [Value] { values.withLock { $0 } }
    var last: Value? { all.last }
    var count: Int { all.count }
}
