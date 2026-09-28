import Foundation

/// Remote config backed by a Cloudflare Worker reading from Workers KV.
///
/// Typical use:
///
/// ```swift
/// let remoteConfig = await CloudflareRemoteConfig.initialize(
///     endpoint: URL(string: "https://my-config.example.workers.dev")!
/// )
/// remoteConfig.setDefaults(["welcome": "Hello"])
/// try? await remoteConfig.fetchAndActivate()
///
/// // Anywhere in the app:
/// let welcome = CloudflareRemoteConfig.shared["welcome"].stringValue
/// ```
///
/// Values are resolved in this order: activated remote value, default value,
/// static value (`""`, `0`, `0.0`, `false`).
///
/// All methods are thread-safe. The getters are synchronous, so they can be
/// used from a SwiftUI `body`.
public final class CloudflareRemoteConfig: Sendable {
    /// Template used when none is given.
    public static let defaultTemplate = "default"

    private static let sharedInstance = Locked<CloudflareRemoteConfig?>(nil)

    /// The instance created by
    /// ``initialize(endpoint:template:clientKey:session:storage:)``.
    ///
    /// - Precondition: `initialize` has been called.
    public static var shared: CloudflareRemoteConfig {
        guard let instance = sharedIfInitialized else {
            preconditionFailure(
                "CloudflareRemoteConfig.initialize(endpoint:) must be called before accessing CloudflareRemoteConfig.shared.")
        }
        return instance
    }

    /// The shared instance, or `nil` before `initialize`.
    static var sharedIfInitialized: CloudflareRemoteConfig? {
        sharedInstance.withLock { $0 }
    }

    /// Creates the ``shared`` instance, loads the cached config from storage
    /// and returns it. Calling it again replaces the shared instance.
    ///
    /// See ``init(endpoint:template:clientKey:session:storage:)`` for the
    /// parameters.
    @discardableResult
    public static func initialize(
        endpoint: URL,
        template: String = defaultTemplate,
        clientKey: String? = nil,
        session: URLSession? = nil,
        storage: (any ConfigStorage)? = nil
    ) async -> CloudflareRemoteConfig {
        let config = CloudflareRemoteConfig(
            endpoint: endpoint, template: template, clientKey: clientKey,
            session: session, storage: storage)
        return await install(config)
    }

    /// ``initialize(endpoint:template:clientKey:session:storage:)`` with
    /// injected dependencies, for tests.
    @discardableResult
    static func initialize(
        endpoint: URL,
        template: String = defaultTemplate,
        clientKey: String? = nil,
        transport: any HTTPTransport,
        storage: any ConfigStorage,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) async -> CloudflareRemoteConfig {
        let config = CloudflareRemoteConfig(
            endpoint: endpoint, template: template, clientKey: clientKey,
            transport: transport, storage: storage, clock: clock)
        return await install(config)
    }

    private static func install(_ config: CloudflareRemoteConfig) async -> CloudflareRemoteConfig {
        await config.ensureInitialized()
        sharedInstance.withLock { $0 = config }
        return config
    }

    /// Clears the shared instance. For tests.
    static func resetShared() {
        sharedInstance.withLock { $0 = nil }
    }

    /// Creates an instance. Most apps use
    /// ``initialize(endpoint:template:clientKey:session:storage:)`` and
    /// ``shared`` instead; create instances directly to read several
    /// templates or Workers. Call ``ensureInitialized()`` before reading
    /// values.
    ///
    /// - Parameters:
    ///   - endpoint: Base URL of the Worker, for example
    ///     `https://my-config.example.workers.dev`. A path prefix and query
    ///     parameters are allowed.
    ///   - template: Which config template to read, matching
    ///     `[A-Za-z0-9_-]{1,64}`.
    ///   - clientKey: Sent as `X-Client-Key` when the Worker requires one.
    ///   - session: The `URLSession` to use. By default the SDK uses its own
    ///     ephemeral session without an HTTP cache.
    ///   - storage: Persistence for the cache. Defaults to
    ///     ``UserDefaultsConfigStorage``.
    /// - Precondition: `endpoint` has a scheme and a host, and `template` is
    ///   valid.
    public convenience init(
        endpoint: URL,
        template: String = defaultTemplate,
        clientKey: String? = nil,
        session: URLSession? = nil,
        storage: (any ConfigStorage)? = nil
    ) {
        self.init(
            endpoint: endpoint, template: template, clientKey: clientKey,
            transport: URLSessionTransport(session: session),
            storage: storage ?? UserDefaultsConfigStorage(),
            clock: { Date() })
    }

    /// The designated initializer, with injected dependencies.
    init(
        endpoint: URL,
        template: String = defaultTemplate,
        clientKey: String? = nil,
        transport: any HTTPTransport,
        storage: any ConfigStorage,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let configURL: URL
        do {
            configURL = try WorkerClient.configURL(endpoint: endpoint, template: template)
        } catch {
            preconditionFailure("Invalid CloudflareRemoteConfig argument: \(error)")
        }
        self.storageKey = PersistedState.storageKey(endpoint: endpoint, template: template)
        self.storage = storage
        self.clock = clock
        self.client = WorkerClient(configURL: configURL, clientKey: clientKey,
                                   transport: transport, clock: clock)
    }

    // MARK: - State

    private struct State: Sendable {
        var defaults: [String: String] = [:]
        var persisted = PersistedState()
        var initialization: Task<Void, Never>?
        var inFlight: (id: UInt64, task: Task<Void, any Error>)?
        var lastFetchID: UInt64 = 0
        var lastWrite: Task<Void, Never>?
    }

    let storageKey: String
    private let storage: any ConfigStorage
    private let clock: @Sendable () -> Date
    let client: WorkerClient
    private let state = Locked(State())

    // MARK: - Settings and defaults

    /// The current fetch settings.
    public var configSettings: RemoteConfigSettings {
        state.withLock { $0.persisted.settings }
    }

    /// Replaces the fetch settings and persists them.
    public func setConfigSettings(_ settings: RemoteConfigSettings) async {
        await ensureInitialized()
        state.withLock { $0.persisted.settings = settings }
        await persist()
    }

    /// Replaces all in-app default values.
    ///
    /// Strings are kept, numbers and booleans are stored as text, and
    /// ``JSONValue`` arrays and objects as JSON text. `nil` values are
    /// ignored. Defaults are not persisted: set them on every launch.
    ///
    /// ```swift
    /// remoteConfig.setDefaults([
    ///     "welcome_message": "Hello",
    ///     "max_items": 10,
    ///     "discount_ratio": 0.0,
    ///     "new_checkout_enabled": false,
    ///     "ad_units": ["banner": "ca-app-pub-1"] as JSONValue,
    /// ])
    /// ```
    public func setDefaults(_ defaults: [String: any RemoteConfigDefaultConvertible]) {
        let converted = defaults.compactMapValues { $0.remoteConfigDefaultString }
        state.withLock { $0.defaults = converted }
    }

    // MARK: - Loading

    /// Loads the cached config from storage. Safe to call several times.
    ///
    /// Every other asynchronous method awaits this internally, but the
    /// synchronous getters only see cached values once it has completed.
    /// ``initialize(endpoint:template:clientKey:session:storage:)`` calls it
    /// for you.
    public func ensureInitialized() async {
        let task = state.withLock { state -> Task<Void, Never> in
            if let initialization = state.initialization { return initialization }
            let initialization = Task { await self.load() }
            state.initialization = initialization
            return initialization
        }
        await task.value
    }

    private func load() async {
        let raw: String?
        do {
            raw = try await storage.value(forKey: storageKey)
        } catch {
            Log.cache.error("Failed to read the cache: \(String(describing: error), privacy: .public)")
            return
        }
        guard let raw else { return }
        do {
            guard let loaded = try PersistedState.decode(raw) else {
                Log.cache.notice("Ignoring a cache that is not in format version 1.")
                return
            }
            state.withLock { $0.persisted = loaded }
        } catch {
            Log.cache.error("Ignoring a corrupt cache: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Fetch and activate

    /// Fetches the latest config from the Worker without activating it.
    ///
    /// Does nothing when the last successful fetch is younger than
    /// ``RemoteConfigSettings/minimumFetchInterval``. Concurrent calls share
    /// one request. A failed fetch never changes the active config.
    ///
    /// - Throws: ``RemoteConfigError``, and nothing else.
    public func fetch() async throws {
        try await startFetch().value
    }

    /// Makes the last fetched config available to the getters.
    ///
    /// - Returns: `true` when a fetched config that differs from the active
    ///   one was activated, `false` when there was nothing new.
    @discardableResult
    public func activate() async -> Bool {
        await ensureInitialized()
        let activated = state.withLock { state -> Bool in
            guard let fetched = state.persisted.fetched else { return false }
            state.persisted.active = fetched
            state.persisted.fetched = nil
            return true
        }
        guard activated else { return false }
        await persist()
        return true
    }

    /// Calls ``fetch()`` then ``activate()``.
    ///
    /// - Returns: The result of ``activate()``.
    /// - Throws: ``RemoteConfigError``, and nothing else.
    @discardableResult
    public func fetchAndActivate() async throws -> Bool {
        try await fetch()
        return await activate()
    }

    /// Returns the fetch in flight, or starts one. The shared task is never
    /// cancelled by its callers.
    func startFetch() -> Task<Void, any Error> {
        state.withLock { state -> Task<Void, any Error> in
            if let inFlight = state.inFlight { return inFlight.task }
            state.lastFetchID &+= 1
            let id = state.lastFetchID
            let task = Task<Void, any Error> {
                // This `defer` needs the lock, which is held until `inFlight`
                // is set below, so it can never clear `inFlight` too early.
                defer {
                    self.state.withLock { state in
                        if state.inFlight?.id == id { state.inFlight = nil }
                    }
                }
                try await self.performFetch()
            }
            state.inFlight = (id, task)
            return task
        }
    }

    private enum FetchDecision {
        case throttled(until: Date)
        case fresh
        case request(etag: String?, timeout: TimeInterval)
    }

    /// Spec §2.7, step by step.
    private func performFetch() async throws {
        await ensureInitialized()
        let now = clock()

        let decision = state.withLock { state -> FetchDecision in
            // 1. An active throttle fails without a request.
            if let end = state.persisted.throttleEndTime, now < end {
                state.persisted.lastFetchStatus = .throttled
                return .throttled(until: end)
            }
            // 2. A fresh enough config needs no request, unless the clock
            //    moved backwards.
            if let last = state.persisted.lastSuccessfulFetch,
               now.timeIntervalSince(last) < state.persisted.settings.minimumFetchInterval,
               !(now < last) {
                return .fresh
            }
            return .request(etag: state.persisted.etag,
                            timeout: state.persisted.settings.fetchTimeout)
        }

        switch decision {
        case .throttled(let end):
            throw RemoteConfigError(
                code: .throttled,
                message: "Fetch is throttled until \(end).",
                throttleEndTime: end)
        case .fresh:
            return
        case .request(let etag, let timeout):
            // 3. Request with the stored ETag.
            let result: WorkerFetchResult
            do {
                result = try await client.fetch(etag: etag, timeout: timeout)
            } catch {
                // 4. Record the failure, persist and rethrow.
                state.withLock { state in
                    if error.code == .throttled {
                        state.persisted.throttleEndTime = error.throttleEndTime
                        state.persisted.lastFetchStatus = .throttled
                    } else {
                        state.persisted.lastFetchStatus = .failure
                    }
                }
                await persist()
                throw error
            }
            let finished = clock()
            state.withLock { state in
                switch result {
                case .fetched(let snapshot, let etag):
                    state.persisted.etag = etag
                    let active = state.persisted.active ?? .empty
                    // Only keep a pending config when it differs from the
                    // active one.
                    state.persisted.fetched = snapshot.entries == active.entries ? nil : snapshot
                case .notModified:
                    break // Whatever is pending or active is still current.
                }
                state.persisted.lastSuccessfulFetch = finished
                state.persisted.throttleEndTime = nil
                state.persisted.lastFetchStatus = .success
            }
            // 5. Persist.
            await persist()
        }
    }

    /// Persists the current state. Writes run one after the other, in the
    /// order of the calls, so the last call wins. Storage failures are
    /// logged, never thrown.
    private func persist() async {
        let storage = self.storage
        let key = storageKey
        let write = state.withLock { state -> Task<Void, Never> in
            let json = state.persisted.encoded
            let previous = state.lastWrite
            let write = Task {
                await previous?.value
                do {
                    try await storage.setValue(json, forKey: key)
                } catch {
                    Log.cache.error("Failed to write the cache: \(String(describing: error), privacy: .public)")
                }
            }
            state.lastWrite = write
            return write
        }
        await write.value
    }

    // MARK: - Values

    /// The value for `key`: the activated remote value, else the default,
    /// else a static value.
    public subscript(key: String) -> RemoteConfigValue {
        configValue(forKey: key)
    }

    /// The value for `key`: the activated remote value, else the default,
    /// else a static value.
    public func configValue(forKey key: String) -> RemoteConfigValue {
        state.withLock { state -> RemoteConfigValue in
            if let remote = state.persisted.active?.entries[key] {
                return RemoteConfigValue(remote, source: .remote)
            }
            if let fallback = state.defaults[key] {
                return RemoteConfigValue(fallback, source: .default)
            }
            return RemoteConfigValue(nil, source: .static)
        }
    }

    /// The value for `key` from one `source` only, or a static value when
    /// that source has none.
    public func configValue(forKey key: String, source: RemoteConfigSource) -> RemoteConfigValue {
        state.withLock { state -> RemoteConfigValue in
            switch source {
            case .remote:
                if let remote = state.persisted.active?.entries[key] {
                    return RemoteConfigValue(remote, source: .remote)
                }
            case .default:
                if let fallback = state.defaults[key] {
                    return RemoteConfigValue(fallback, source: .default)
                }
            case .static:
                break
            }
            return RemoteConfigValue(nil, source: .static)
        }
    }

    /// The keys that have a value in `source`, sorted. Always empty for
    /// ``RemoteConfigSource/static``.
    public func allKeys(from source: RemoteConfigSource) -> [String] {
        state.withLock { state -> [String] in
            switch source {
            case .remote: return (state.persisted.active?.entries.keys).map { $0.sorted() } ?? []
            case .default: return state.defaults.keys.sorted()
            case .static: return []
            }
        }
    }

    /// Every known key, remote or default, with its resolved value.
    public func allValues() -> [String: RemoteConfigValue] {
        state.withLock { state -> [String: RemoteConfigValue] in
            var values: [String: RemoteConfigValue] = [:]
            for (key, value) in state.defaults {
                values[key] = RemoteConfigValue(value, source: .default)
            }
            for (key, value) in state.persisted.active?.entries ?? [:] {
                values[key] = RemoteConfigValue(value, source: .remote)
            }
            return values
        }
    }

    /// Outcome of the most recent fetch attempt.
    public var lastFetchStatus: RemoteConfigFetchStatus {
        state.withLock { $0.persisted.lastFetchStatus }
    }

    /// When the last successful fetch completed, or `nil` if none has.
    public var lastFetchTime: Date? {
        state.withLock { $0.persisted.lastSuccessfulFetch }
    }
}
