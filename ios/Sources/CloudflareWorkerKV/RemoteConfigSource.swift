/// Where a ``RemoteConfigValue`` came from.
public enum RemoteConfigSource: String, Sendable, CaseIterable {
    /// The value comes from the activated remote config.
    case remote
    /// The value comes from the defaults passed to
    /// ``CloudflareRemoteConfig/setDefaults(_:)``.
    case `default`
    /// The key is unknown: there is neither a remote value nor a default.
    case `static`
}
