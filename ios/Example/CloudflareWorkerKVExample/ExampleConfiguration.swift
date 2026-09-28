import Foundation

/// The Worker URL and optional client key, injected at build time:
/// `CF_CONFIG_ENDPOINT` and `CF_CLIENT_KEY` (see `Config/Example.xcconfig`)
/// end up in Info.plist as `CFConfigEndpoint` and `CFClientKey`.
struct ExampleConfiguration: Sendable {
    /// The value as configured, possibly empty or invalid.
    let rawEndpoint: String
    /// The endpoint, when it is an absolute URL with a scheme and a host.
    let endpoint: URL?
    /// `nil` when not configured.
    let clientKey: String?

    init(bundle: Bundle = .main) {
        rawEndpoint = Self.string(forKey: "CFConfigEndpoint", in: bundle)
        if let url = URL(string: rawEndpoint),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.scheme?.isEmpty == false,
           components.host?.isEmpty == false {
            endpoint = url
        } else {
            endpoint = nil
        }
        let key = Self.string(forKey: "CFClientKey", in: bundle)
        clientKey = key.isEmpty ? nil : key
    }

    private static func string(forKey key: String, in bundle: Bundle) -> String {
        let value = bundle.object(forInfoDictionaryKey: key) as? String ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
