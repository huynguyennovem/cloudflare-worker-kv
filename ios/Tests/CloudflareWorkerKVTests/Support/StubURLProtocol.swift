import Foundation
@testable import CloudflareWorkerKV

/// A `URLProtocol` that answers requests of a `URLSession` configured with
/// ``StubURLProtocol/makeSession()``, so the real `URLSessionTransport` can be
/// tested without a network. State is global: suites using it are serialized.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case response(status: Int, headers: [String: String], body: Data)
        case failure(URLError)
        case never
    }

    typealias Handler = @Sendable (URLRequest) -> Reply

    private static let handler = Locked<Handler?>(nil)
    private static let recorded = Locked<[URLRequest]>([])

    /// Sets how requests are answered and forgets recorded requests.
    static func reset(_ newHandler: @escaping Handler) {
        handler.withLock { $0 = newHandler }
        recorded.withLock { $0 = [] }
    }

    /// Every request received, in order.
    static var requests: [URLRequest] { recorded.withLock { $0 } }

    /// An ephemeral session that sends everything to this protocol.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorded.withLock { $0.append(request) }
        guard let reply = Self.handler.withLock({ $0 })?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch reply {
        case .response(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .never:
            break
        }
    }

    override func stopLoading() {}
}
