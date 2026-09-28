package io.github.huynguyennovem.cloudflareworkerkv

import android.content.Context
import io.github.huynguyennovem.cloudflareworkerkv.RemoteConfigException.Code
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Remote config backed by a Cloudflare Worker reading from Workers KV.
 *
 * Typical use, from an `Application` or a startup coroutine:
 *
 * ```kotlin
 * val remoteConfig = CloudflareRemoteConfig.initialize(
 *     context,
 *     endpoint = "https://my-config.example.workers.dev",
 * )
 * remoteConfig.setDefaults(mapOf("welcome" to "Hello"))
 * remoteConfig.fetchAndActivate()
 * val welcome = CloudflareRemoteConfig.instance.getString("welcome")
 * ```
 *
 * Values are resolved in this order: activated remote value, default value, static value
 * (`""`, `0`, `0.0`, `false`).
 *
 * All methods are thread-safe. The getters never block and never suspend; they see the cached
 * config once [ensureInitialized] has completed, which [initialize] and every suspending
 * method do for you.
 */
public class CloudflareRemoteConfig internal constructor(
    endpoint: String,
    template: String,
    clientKey: String?,
    transport: HttpTransport,
    private val storage: ConfigStorage,
    private val clock: Clock,
    private val logger: Logger,
    coroutineContext: CoroutineContext,
) {
    /**
     * Creates an instance. Most apps should use [initialize] and [instance] instead; create
     * instances directly to read several templates or Workers at once. Each
     * endpoint/template pair has its own cache.
     *
     * @param context any context; only its application context is kept, by the default
     *   [storage].
     * @param endpoint base URL of the Worker, e.g. `https://my-config.example.workers.dev`. A
     *   path prefix and query parameters are allowed.
     * @param template which config template to read; must match `[A-Za-z0-9_-]{1,64}`.
     * @param clientKey sent as `X-Client-Key` when the Worker requires one.
     * @param transport sends the HTTP request.
     * @param storage persists the cache.
     * @throws IllegalArgumentException if [template] is invalid, or if [endpoint] is not an
     *   absolute URL with a scheme and a host.
     */
    @JvmOverloads
    public constructor(
        context: Context,
        endpoint: String,
        template: String = DEFAULT_TEMPLATE,
        clientKey: String? = null,
        transport: HttpTransport = HttpUrlConnectionTransport(),
        storage: ConfigStorage = SharedPreferencesConfigStorage(context),
    ) : this(
        endpoint = endpoint,
        template = template,
        clientKey = clientKey,
        transport = transport,
        storage = storage,
        clock = Clock.SYSTEM,
        logger = Logger.ANDROID,
        coroutineContext = Dispatchers.Default,
    )

    init {
        require(TEMPLATE_PATTERN.matches(template)) {
            "template must match [A-Za-z0-9_-]{1,64}, was \"$template\"."
        }
    }

    private val storageKey = "$STORAGE_KEY_PREFIX$endpoint|$template"
    private val client = WorkerClient(endpoint, template, clientKey, transport, clock)

    // Shared work (loading the cache, the in-flight fetch) runs in this scope, so that a
    // cancelled caller does not cancel it for the other callers.
    private val scope = CoroutineScope(coroutineContext.minusKey(Job) + SupervisorJob())

    private val lock = Any()

    @Volatile
    private var state = State.INITIAL

    @Volatile
    private var defaults: Map<String, String> = emptyMap()

    private val initialization: Deferred<Unit> = scope.async(start = CoroutineStart.LAZY) { load() }

    private val fetchLock = Any()
    private var inFlight: Deferred<Unit>? = null // Guarded by fetchLock.

    private val writeMutex = Mutex()

    @Volatile
    private var disposed = false

    /** The last fetch time and status, and the current settings. */
    public val info: RemoteConfigInfo
        get() {
            val current = state
            return RemoteConfigInfo(
                fetchTimeMillis = current.lastSuccessfulFetchMillis ?: -1L,
                lastFetchStatus = current.lastFetchStatus,
                configSettings = current.settings,
            )
        }

    /**
     * Loads the cached config from storage. Safe to call several times.
     *
     * Every other suspending method awaits this internally, but the getters only see cached
     * values once it has completed.
     *
     * @throws IllegalStateException if this instance was replaced by [initialize] before
     *   loading completed.
     */
    public suspend fun ensureInitialized() {
        initialization.awaitShared()
    }

    /**
     * Replaces the fetch settings and persists them.
     *
     * @throws IllegalStateException if this instance was replaced by [initialize] before
     *   loading completed.
     */
    public suspend fun setConfigSettings(settings: RemoteConfigSettings) {
        ensureInitialized()
        synchronized(lock) { state = state.copy(settings = settings) }
        persist()
    }

    /**
     * Replaces the in-app default values. Defaults are not persisted: set them on every
     * launch.
     *
     * Supported values: [String]; any [Number] or [Boolean] (stored with `toString()`); a
     * [Map] with [String] keys, a [Collection] or an array (stored as compact JSON). `null`
     * values are ignored.
     *
     * @throws IllegalArgumentException for any other type; the previous defaults are kept.
     */
    public fun setDefaults(defaults: Map<String, Any?>) {
        this.defaults = DefaultsEncoder.encode(defaults)
    }

    /**
     * Fetches the latest config from the Worker without activating it.
     *
     * Returns without a request if the last successful fetch is younger than
     * [RemoteConfigSettings.minimumFetchInterval]. Concurrent calls share a single request;
     * cancelling one caller does not cancel it for the others. The active config is never
     * modified by a fetch.
     *
     * @throws RemoteConfigException when the fetch fails.
     * @throws IllegalStateException if this instance was replaced by [initialize].
     */
    public suspend fun fetch() {
        val deferred = synchronized(fetchLock) {
            inFlight ?: scope.async(start = CoroutineStart.LAZY) { fetchOnce() }.also { created ->
                inFlight = created
                created.invokeOnCompletion {
                    synchronized(fetchLock) { if (inFlight === created) inFlight = null }
                }
            }
        }
        deferred.start()
        deferred.awaitShared()
    }

    /**
     * Makes the last fetched config available to the getters, and persists it.
     *
     * @return `true` if a fetched config differing from the active one was activated, `false`
     *   if there was nothing new to activate.
     * @throws IllegalStateException if this instance was replaced by [initialize] before
     *   loading completed.
     */
    public suspend fun activate(): Boolean {
        ensureInitialized()
        val activated = synchronized(lock) {
            val fetched = state.fetched
            if (fetched != null) state = state.copy(active = fetched, fetched = null)
            fetched != null
        }
        if (activated) persist()
        return activated
    }

    /**
     * Calls [fetch], then [activate].
     *
     * @return the result of [activate].
     * @throws RemoteConfigException when the fetch fails.
     * @throws IllegalStateException if this instance was replaced by [initialize].
     */
    public suspend fun fetchAndActivate(): Boolean {
        fetch()
        return activate()
    }

    /** Returns the value for [key] as a [String]. See [RemoteConfigValue.asString]. */
    public fun getString(key: String): String = getValue(key).asString()

    /** Returns the value for [key] as a [Boolean]. See [RemoteConfigValue.asBoolean]. */
    public fun getBoolean(key: String): Boolean = getValue(key).asBoolean()

    /** Returns the value for [key] as a [Long]. See [RemoteConfigValue.asLong]. */
    public fun getLong(key: String): Long = getValue(key).asLong()

    /** Returns the value for [key] as a [Double]. See [RemoteConfigValue.asDouble]. */
    public fun getDouble(key: String): Double = getValue(key).asDouble()

    /** Returns the [RemoteConfigValue] for [key], including its [ValueSource]. */
    public fun getValue(key: String): RemoteConfigValue = resolve(key, state, defaults)

    /** Same as [getValue], so that `remoteConfig["key"]` works. */
    public operator fun get(key: String): RemoteConfigValue = getValue(key)

    /** Returns every known key (defaults and activated remote values) with its resolved value. */
    public fun getAll(): Map<String, RemoteConfigValue> {
        val current = state
        val currentDefaults = defaults
        val keys = LinkedHashSet(currentDefaults.keys)
        current.active?.let { keys.addAll(it.entries.keys) }
        val all = LinkedHashMap<String, RemoteConfigValue>()
        for (key in keys) all[key] = resolve(key, current, currentDefaults)
        return all
    }

    /**
     * Stops this instance: cancels its work in progress and stops writing to the cache, so
     * that it cannot overwrite the cache of the instance that replaced it. The getters keep
     * returning the last values.
     */
    internal fun dispose() {
        disposed = true
        scope.cancel()
    }

    private suspend fun fetchOnce() {
        ensureInitialized()
        val now = clock.nowMillis()
        val current = state

        val throttleEnd = current.throttleEndMillis
        if (throttleEnd != null && now < throttleEnd) {
            synchronized(lock) { state = state.copy(lastFetchStatus = FetchStatus.THROTTLED) }
            throw RemoteConfigException(
                Code.THROTTLED,
                "Fetch is throttled until ${formatTime(throttleEnd)}.",
                throttleEndTimeMillis = throttleEnd,
            )
        }

        val lastSuccess = current.lastSuccessfulFetchMillis
        if (lastSuccess != null && now >= lastSuccess) {
            val elapsed = now - lastSuccess // Negative only on overflow, i.e. very old.
            if (elapsed >= 0 && elapsed < current.settings.minimumFetchInterval.inWholeMilliseconds) {
                return // The cached config is fresh enough.
            }
        }

        try {
            val result = client.fetch(current.etag, current.settings.fetchTimeout)
            val finishedAt = clock.nowMillis()
            synchronized(lock) {
                var next = state
                if (result is WorkerFetchResult.Fetched) {
                    val active = next.active ?: ConfigSnapshot.EMPTY
                    // Only keep a pending config when it differs from the active one.
                    val fetched = if (result.snapshot.entries == active.entries) null else result.snapshot
                    next = next.copy(etag = result.etag, fetched = fetched)
                }
                // NotModified: whatever is pending or active is still current.
                state = next.copy(
                    lastSuccessfulFetchMillis = finishedAt,
                    throttleEndMillis = null,
                    lastFetchStatus = FetchStatus.SUCCESS,
                )
            }
        } catch (e: RemoteConfigException) {
            synchronized(lock) {
                state = if (e.code == Code.THROTTLED) {
                    state.copy(throttleEndMillis = e.throttleEndTimeMillis, lastFetchStatus = FetchStatus.THROTTLED)
                } else {
                    state.copy(lastFetchStatus = FetchStatus.FAILURE)
                }
            }
            throw e
        } finally {
            persist()
        }
    }

    private suspend fun load() {
        val raw = try {
            storage.read(storageKey)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            logger.warn("Failed to read the config cache.", e)
            return
        } ?: return

        val loaded = try {
            PersistedState.decode(raw)
        } catch (e: Exception) {
            // Not the throwable: parser messages may quote the cached config.
            logger.warn("Ignoring a corrupt config cache (${e.javaClass.simpleName}).", null)
            return
        }
        if (loaded == null) {
            logger.warn("Ignoring a config cache with an unknown format.", null)
            return
        }
        synchronized(lock) { state = loaded }
    }

    /**
     * Writes the current state. Writes are serialised and each one reads the state when it
     * starts, so the last write always wins. Storage failures are logged, never thrown.
     */
    private suspend fun persist() {
        withContext(NonCancellable) {
            writeMutex.withLock {
                if (disposed) return@withLock
                try {
                    storage.write(storageKey, PersistedState.encode(state))
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    logger.warn("Failed to write the config cache.", e)
                }
            }
        }
    }

    /** Awaits shared work, telling a disposed instance apart from a cancelled caller. */
    private suspend fun <T> Deferred<T>.awaitShared(): T = try {
        await()
    } catch (e: CancellationException) {
        currentCoroutineContext().ensureActive() // The caller itself was cancelled.
        if (disposed) {
            throw IllegalStateException(
                "This CloudflareRemoteConfig was replaced by CloudflareRemoteConfig.initialize().",
                e,
            )
        }
        throw e
    }

    public companion object {
        /** Template used when none is given. */
        public const val DEFAULT_TEMPLATE: String = "default"

        private const val STORAGE_KEY_PREFIX = "cloudflare_worker_kv:"
        private val TEMPLATE_PATTERN = Regex("[A-Za-z0-9_-]{1,64}")

        private val instanceLock = Any()

        @Volatile
        private var current: CloudflareRemoteConfig? = null

        /**
         * The instance created by [initialize].
         *
         * @throws IllegalStateException if [initialize] has not been called.
         */
        @JvmStatic
        public val instance: CloudflareRemoteConfig
            get() = current ?: throw IllegalStateException(
                "CloudflareRemoteConfig.initialize() must be called before accessing " +
                    "CloudflareRemoteConfig.instance.",
            )

        /**
         * Creates the shared [instance], loads the cached config from storage and returns it.
         *
         * Calling it again replaces the shared instance. The previous instance is disposed:
         * its getters keep working, but its suspending methods throw [IllegalStateException]
         * and it no longer writes the cache.
         *
         * See the [CloudflareRemoteConfig] constructor for the parameters.
         *
         * @throws IllegalArgumentException if [template] is invalid, or if [endpoint] is not
         *   an absolute URL with a scheme and a host.
         */
        @JvmStatic
        public suspend fun initialize(
            context: Context,
            endpoint: String,
            template: String = DEFAULT_TEMPLATE,
            clientKey: String? = null,
            transport: HttpTransport = HttpUrlConnectionTransport(),
            storage: ConfigStorage = SharedPreferencesConfigStorage(context),
        ): CloudflareRemoteConfig = install(
            CloudflareRemoteConfig(context, endpoint, template, clientKey, transport, storage),
        )

        /** Loads [config] and makes it the shared [instance]. */
        internal suspend fun install(config: CloudflareRemoteConfig): CloudflareRemoteConfig {
            config.ensureInitialized()
            val previous = synchronized(instanceLock) { current.also { current = config } }
            if (previous !== config) previous?.dispose()
            return config
        }

        /** Clears the shared [instance]. For tests. */
        internal fun resetInstance() {
            synchronized(instanceLock) { current.also { current = null } }?.dispose()
        }

        private fun resolve(key: String, state: State, defaults: Map<String, String>): RemoteConfigValue {
            state.active?.entries?.get(key)?.let { return RemoteConfigValue(it, ValueSource.REMOTE) }
            defaults[key]?.let { return RemoteConfigValue(it, ValueSource.DEFAULT) }
            return RemoteConfigValue(null, ValueSource.STATIC)
        }

        private fun formatTime(millis: Long): String =
            SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
                .apply { timeZone = TimeZone.getTimeZone("UTC") }
                .format(Date(millis))
    }
}
