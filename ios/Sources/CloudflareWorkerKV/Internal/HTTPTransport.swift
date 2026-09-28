import Foundation

/// An HTTP response, with header names lowercased.
struct HTTPResponse: Sendable, Equatable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last })
        self.body = body
    }
}

/// Sends one HTTP request. Implementations must honour task cancellation,
/// which is how `fetchTimeout` stops a request.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// The production transport, backed by `URLSession`.
final class URLSessionTransport: HTTPTransport {
    let session: URLSession
    private let ownsSession: Bool

    /// Uses `session`, or a new ephemeral session without any HTTP cache,
    /// which this transport then owns and invalidates.
    init(session: URLSession?) {
        if let session {
            self.session = session
            ownsSession = false
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
            ownsSession = true
        }
    }

    deinit {
        if ownsSession { session.finishTasksAndInvalidate() }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}
