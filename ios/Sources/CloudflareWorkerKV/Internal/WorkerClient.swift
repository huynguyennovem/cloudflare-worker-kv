import Foundation

/// Result of ``WorkerClient/fetch(etag:timeout:)``.
enum WorkerFetchResult: Sendable, Equatable {
    /// The Worker returned a config, with its `ETag` header (verbatim).
    case fetched(ConfigSnapshot, etag: String?)
    /// The Worker returned `304 Not Modified`.
    case notModified
}

/// Low-level HTTP client for the config Worker (spec §1, §2.1 to §2.3).
struct WorkerClient: Sendable {
    /// An invalid endpoint or template: a programming error.
    struct InvalidArgument: Error, CustomStringConvertible {
        let description: String
    }

    /// Path of the config endpoint, relative to the Worker endpoint.
    static let configPath = "v1/config"

    /// Used when a 429 response carries no usable `Retry-After` header.
    static let defaultThrottleDuration: TimeInterval = 60

    /// Fully resolved URL of the config endpoint.
    let configURL: URL
    /// Sent as `X-Client-Key` when not `nil`.
    let clientKey: String?
    let transport: any HTTPTransport
    let clock: @Sendable () -> Date

    init(configURL: URL, clientKey: String?, transport: any HTTPTransport,
         clock: @escaping @Sendable () -> Date) {
        self.configURL = configURL
        self.clientKey = clientKey
        self.transport = transport
        self.clock = clock
    }

    // MARK: - URL

    /// Checks that `template` matches `^[A-Za-z0-9_-]{1,64}$`.
    static func validateTemplate(_ template: String) throws(InvalidArgument) {
        let bytes = template.utf8
        let valid = (1...64).contains(bytes.count) && bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
        guard valid else {
            throw InvalidArgument(description: "template must match [A-Za-z0-9_-]{1,64}, got \"\(template)\".")
        }
    }

    /// Builds the request URL (spec §2.1): removes one trailing `/` from the
    /// path and appends `/v1/config`, keeps the scheme, host, port and query
    /// (verbatim), sets `template` (in place when present) and drops the
    /// fragment.
    static func configURL(endpoint: URL, template: String) throws(InvalidArgument) -> URL {
        try validateTemplate(template)
        guard var components = URLComponents(url: endpoint.absoluteURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, !scheme.isEmpty,
              let host = components.percentEncodedHost, !host.isEmpty
        else {
            throw InvalidArgument(description: "endpoint must be an absolute URL with a scheme and a host, got \"\(endpoint.absoluteString)\".")
        }
        components.percentEncodedFragment = nil

        var path = components.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = "\(path)/\(configPath)"

        // percentEncodedQueryItems keeps the existing query exactly as it was
        // written. Items without a name (`?&x=1`) are dropped.
        var items = (components.percentEncodedQueryItems ?? []).filter { !$0.name.isEmpty }
        let templateItem = URLQueryItem(name: "template", value: template)
        if let index = items.firstIndex(where: { $0.name == "template" }) {
            items[index] = templateItem
            items = items.enumerated()
                .filter { $0.offset == index || $0.element.name != "template" }
                .map(\.element)
        } else {
            items.append(templateItem)
        }
        components.percentEncodedQueryItems = items

        guard let url = components.url else {
            throw InvalidArgument(description: "Cannot build a config URL from \"\(endpoint.absoluteString)\".")
        }
        return url
    }

    // MARK: - Fetch

    /// Fetches the config, sending `If-None-Match: etag` when `etag` is set.
    /// `timeout` limits the whole request, body included.
    func fetch(etag: String?, timeout: TimeInterval) async throws(RemoteConfigError) -> WorkerFetchResult {
        var request = URLRequest(url: configURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let clientKey { request.setValue(clientKey, forHTTPHeaderField: "X-Client-Key") }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let response: HTTPResponse
        do {
            let transport = self.transport
            let sent = request
            response = try await withTimeout(seconds: timeout) { try await transport.send(sent) }
        } catch let error {
            if error is TimeoutError || (error as? URLError)?.code == .timedOut {
                throw RemoteConfigError(
                    code: .timeout,
                    message: "No response within \(RemoteConfigSettings.milliseconds(timeout)) ms.",
                    underlyingError: error)
            }
            throw RemoteConfigError(
                code: .networkError,
                message: "Request to \(configURL.absoluteString) failed: \(error.localizedDescription)",
                underlyingError: error)
        }
        return try Self.interpret(response: response, sentETag: etag, now: clock())
    }

    /// Maps one HTTP response to a fetch outcome (spec §2.3). `now` is the
    /// time the response arrived, used for the throttle end.
    static func interpret(response: HTTPResponse, sentETag: String?, now: Date) throws(RemoteConfigError) -> WorkerFetchResult {
        let status = response.statusCode
        switch status {
        case 304:
            guard sentETag != nil else {
                throw RemoteConfigError(
                    code: .invalidResponse,
                    message: "Received 304 for an unconditional request.",
                    statusCode: status)
            }
            return .notModified
        case 200:
            let etag = response.headers["etag"]
            do {
                let json = try JSONValue(parsing: response.body)
                let snapshot = try ConfigSnapshot(json: json, fallbackVersion: stripETag(etag))
                return .fetched(snapshot, etag: etag)
            } catch let error {
                let reason = (error as? ConfigSnapshot.FormatError)?.description ?? "not valid JSON."
                throw RemoteConfigError(
                    code: .invalidResponse,
                    message: "Malformed config payload: \(reason)",
                    statusCode: status,
                    underlyingError: error)
            }
        case 401, 403:
            throw RemoteConfigError(
                code: .unauthorized,
                message: "The Worker rejected the client key.",
                statusCode: status)
        case 429:
            throw RemoteConfigError(
                code: .throttled,
                message: "Fetch is rate limited.",
                statusCode: status,
                throttleEndTime: now.addingTimeInterval(retryAfter(response.headers["retry-after"])))
        default:
            throw RemoteConfigError(
                code: .serverError,
                message: "Unexpected response: \(describeError(response))",
                statusCode: status)
        }
    }

    /// `Retry-After` in seconds: a trimmed, non-negative integer, else 60.
    static func retryAfter(_ header: String?) -> TimeInterval {
        let text = header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let seconds = Int64(text, radix: 10), seconds >= 0 else {
            return defaultThrottleDuration
        }
        return TimeInterval(seconds)
    }

    /// The ETag without a `W/` prefix and surrounding quotes.
    static func stripETag(_ etag: String?) -> String? {
        guard let etag else { return nil }
        var tag = Substring(etag.trimmingCharacters(in: .whitespacesAndNewlines))
        if tag.hasPrefix("W/") { tag = tag.dropFirst(2) }
        let bytes = tag.utf8
        if bytes.count >= 2, bytes.first == UInt8(ascii: "\""), bytes.last == UInt8(ascii: "\"") {
            // Both quotes are single ASCII bytes, so this keeps valid UTF-8.
            return String(decoding: bytes.dropFirst().dropLast(), as: UTF8.self)
        }
        return String(tag)
    }

    /// `<error> - <message>` from a JSON error body, else the reason phrase.
    static func describeError(_ response: HTTPResponse) -> String {
        if let body = try? JSONValue(parsing: response.body),
           case .string(let error)? = body["error"] {
            if case .string(let message)? = body["message"] {
                return "\(error) - \(message)"
            }
            return error
        }
        return HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
    }
}
