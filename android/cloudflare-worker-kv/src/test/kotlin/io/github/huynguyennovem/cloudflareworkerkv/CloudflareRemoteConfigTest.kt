@file:OptIn(ExperimentalCoroutinesApi::class)

package io.github.huynguyennovem.cloudflareworkerkv

import io.github.huynguyennovem.cloudflareworkerkv.RemoteConfigException.Code
import io.github.huynguyennovem.cloudflareworkerkv.helpers.FakeClock
import io.github.huynguyennovem.cloudflareworkerkv.helpers.FakeSharedPreferences
import io.github.huynguyennovem.cloudflareworkerkv.helpers.FakeWorker
import io.github.huynguyennovem.cloudflareworkerkv.helpers.RecordingLogger
import io.github.huynguyennovem.cloudflareworkerkv.helpers.SlowStorage
import io.github.huynguyennovem.cloudflareworkerkv.helpers.ThrowingStorage
import io.github.huynguyennovem.cloudflareworkerkv.helpers.transport
import java.io.IOException
import java.util.Date
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/** Port of flutter/test/cloudflare_remote_config_test.dart, plus Kotlin-specific cases. */
class CloudflareRemoteConfigTest {
    private lateinit var worker: FakeWorker
    private lateinit var storage: InMemoryConfigStorage
    private lateinit var clock: FakeClock
    private lateinit var logger: RecordingLogger
    private val created = mutableListOf<CloudflareRemoteConfig>()

    private val cacheKey = "cloudflare_worker_kv:$ENDPOINT|default"

    @BeforeTest
    fun setUp() {
        worker = FakeWorker(mapOf("welcome" to "Hello", "max_items" to "10"))
        storage = InMemoryConfigStorage()
        clock = FakeClock()
        logger = RecordingLogger()
    }

    @AfterTest
    fun tearDown() {
        CloudflareRemoteConfig.resetInstance()
        created.forEach { it.dispose() }
    }

    private fun TestScope.create(
        transport: HttpTransport = worker,
        storageOverride: ConfigStorage = storage,
        template: String = "default",
        clientKey: String? = null,
    ): CloudflareRemoteConfig = CloudflareRemoteConfig(
        endpoint = ENDPOINT,
        template = template,
        clientKey = clientKey,
        transport = transport,
        storage = storageOverride,
        clock = clock,
        logger = logger,
        coroutineContext = StandardTestDispatcher(testScheduler),
    ).also { created += it }

    private suspend fun TestScope.ready(interval: Duration = Duration.ZERO): CloudflareRemoteConfig {
        val rc = create()
        rc.ensureInitialized()
        rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval = interval))
        return rc
    }

    private inline fun assertFailsWithCode(code: Code, block: () -> Unit): RemoteConfigException {
        val e = assertFailsWith<RemoteConfigException> { block() }
        assertEquals(code, e.code, e.toString())
        return e
    }

    // --- initial state ---

    @Test
    fun `initial state - before any fetch`() = runTest {
        val rc = ready()
        assertEquals(FetchStatus.NO_FETCH_YET, rc.info.lastFetchStatus)
        assertEquals(-1L, rc.info.fetchTimeMillis)
        assertTrue(rc.getAll().isEmpty())
        assertEquals(RemoteConfigValue(null, ValueSource.STATIC), rc.getValue("missing"))
    }

    @Test
    fun `initial state - rejects invalid template names`() = runTest {
        for (template in listOf("", "a/b", "x".repeat(65), "a b", "abc\n")) {
            assertFailsWith<IllegalArgumentException>(template) { create(template = template) }
        }
    }

    // --- defaults ---

    @Test
    fun `defaults - are used until a remote value is activated`() = runTest {
        val rc = ready()
        rc.setDefaults(
            mapOf(
                "welcome" to "Default",
                "max_items" to 5,
                "ratio" to 0.5,
                "dark" to true,
                "json" to mapOf("a" to 1),
                "list" to listOf(1, 2),
                "ignored" to null,
            ),
        )
        assertEquals("Default", rc.getString("welcome"))
        assertEquals(5L, rc.getLong("max_items"))
        assertEquals(0.5, rc.getDouble("ratio"))
        assertTrue(rc.getBoolean("dark"))
        assertEquals("""{"a":1}""", rc.getString("json"))
        assertEquals("[1,2]", rc.getString("list"))
        assertEquals(ValueSource.STATIC, rc.getValue("ignored").source)
        assertEquals(ValueSource.DEFAULT, rc.getValue("welcome").source)
    }

    @Test
    fun `defaults - unsupported types throw`() = runTest {
        val rc = ready()
        rc.setDefaults(mapOf("kept" to "yes"))
        assertFailsWith<IllegalArgumentException> { rc.setDefaults(mapOf("x" to Date(0))) }
        assertFailsWith<IllegalArgumentException> { rc.setDefaults(mapOf("x" to 'c')) }
        assertFailsWith<IllegalArgumentException> { rc.setDefaults(mapOf("x" to mapOf(1 to "a"))) }
        assertFailsWith<IllegalArgumentException> { rc.setDefaults(mapOf("x" to listOf(Any()))) }
        assertFailsWith<IllegalArgumentException> { rc.setDefaults(mapOf("x" to listOf(Double.NaN))) }
        assertEquals("yes", rc.getString("kept"), "a rejected call keeps the previous defaults")
    }

    @Test
    fun `defaults - setDefaults replaces previous defaults`() = runTest {
        val rc = ready()
        rc.setDefaults(mapOf("a" to "1"))
        rc.setDefaults(mapOf("b" to "2"))
        assertEquals(ValueSource.STATIC, rc.getValue("a").source)
        assertEquals("2", rc.getString("b"))
    }

    @Test
    fun `defaults - numbers, arrays and nested JSON`() = runTest {
        val rc = ready()
        rc.setDefaults(
            mapOf(
                "long" to 5_000_000_000L,
                "float" to 1.5f,
                "array" to arrayOf("a", "/b"),
                "ints" to intArrayOf(1, 2),
                "nested" to mapOf("k" to listOf(true, null, 2.5, mapOf("x" to "y"))),
            ),
        )
        assertEquals(5_000_000_000L, rc.getLong("long"))
        assertEquals("1.5", rc.getString("float"))
        assertEquals("""["a","/b"]""", rc.getString("array"))
        assertEquals("[1,2]", rc.getString("ints"))
        assertEquals("""{"k":[true,null,2.5,{"x":"y"}]}""", rc.getString("nested"))
    }

    // --- fetch & activate ---

    @Test
    fun `fetch & activate - fetch does not change active values until activate`() = runTest {
        val rc = ready()
        rc.setDefaults(mapOf("welcome" to "Default"))
        rc.fetch()
        assertEquals(FetchStatus.SUCCESS, rc.info.lastFetchStatus)
        assertEquals(clock.now, rc.info.fetchTimeMillis)
        assertEquals("Default", rc.getString("welcome"))

        assertTrue(rc.activate())
        assertEquals("Hello", rc.getString("welcome"))
        assertEquals(ValueSource.REMOTE, rc.getValue("welcome").source)
        assertEquals(10L, rc.getLong("max_items"))
        assertEquals(rc.getValue("welcome"), rc["welcome"])
    }

    @Test
    fun `fetch & activate - activate returns false when nothing new`() = runTest {
        val rc = ready()
        assertFalse(rc.activate())
        assertTrue(rc.fetchAndActivate())
        assertFalse(rc.activate())
        // Unchanged remote config -> 304 -> nothing to activate.
        assertFalse(rc.fetchAndActivate())
        assertNotNull(worker.requests.last().headers["If-None-Match"])
    }

    @Test
    fun `fetch & activate - changed remote config is picked up via a new fetch`() = runTest {
        val rc = ready()
        rc.fetchAndActivate()
        worker.entries = mapOf("welcome" to "Updated")
        assertTrue(rc.fetchAndActivate())
        assertEquals("Updated", rc.getString("welcome"))
        // Keys removed remotely fall back to defaults/static.
        assertEquals(ValueSource.STATIC, rc.getValue("max_items").source)
    }

    @Test
    fun `fetch & activate - remote rollback to the active config discards pending fetch`() = runTest {
        val rc = ready()
        rc.fetchAndActivate() // active = A
        val original = worker.entries
        worker.entries = mapOf("welcome" to "B")
        rc.fetch() // pending = B
        worker.entries = original
        rc.fetch() // server back to A
        assertFalse(rc.activate())
        assertEquals("Hello", rc.getString("welcome"))
    }

    @Test
    fun `fetch & activate - empty remote config with nothing active gives nothing to activate`() = runTest {
        worker.entries = emptyMap()
        val rc = ready()
        assertFalse(rc.fetchAndActivate())
        assertEquals(FetchStatus.SUCCESS, rc.info.lastFetchStatus)
    }

    @Test
    fun `fetch & activate - getAll merges defaults and remote values`() = runTest {
        val rc = ready()
        rc.setDefaults(mapOf("welcome" to "Default", "only_default" to "x"))
        rc.fetchAndActivate()
        val all = rc.getAll()
        assertEquals(setOf("welcome", "max_items", "only_default"), all.keys)
        assertEquals(RemoteConfigValue("Hello", ValueSource.REMOTE), all["welcome"])
        assertEquals(ValueSource.DEFAULT, all.getValue("only_default").source)
    }

    @Test
    fun `fetch & activate - client key is sent`() = runTest {
        worker.clientKey = "k"
        val rc = create(clientKey = "k")
        rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval = Duration.ZERO))
        assertTrue(rc.fetchAndActivate())
    }

    // --- minimumFetchInterval ---

    @Test
    fun `minimumFetchInterval - skips the network inside the interval`() = runTest {
        val rc = ready(interval = 1.hours)
        rc.fetch()
        assertEquals(1, worker.requests.size)

        clock.advance(59.minutes)
        rc.fetch()
        assertEquals(1, worker.requests.size)

        clock.advance(1.minutes)
        rc.fetch()
        assertEquals(2, worker.requests.size)
    }

    @Test
    fun `minimumFetchInterval - failed fetches do not start the interval`() = runTest {
        val rc = ready(interval = 1.hours)
        worker.override = { HttpResponse(500, emptyMap()) }
        assertFailsWith<RemoteConfigException> { rc.fetch() }
        worker.override = null
        rc.fetch()
        assertEquals(2, worker.requests.size)
    }

    @Test
    fun `minimumFetchInterval - clock moving backwards does not block fetching`() = runTest {
        val rc = ready(interval = 1.hours)
        rc.fetch()
        clock.advance((-2).hours)
        rc.fetch()
        assertEquals(2, worker.requests.size)
    }

    // --- failures ---

    private fun failureCase(code: Code, response: suspend (HttpRequest) -> HttpResponse) = runTest {
        val rc = ready()
        rc.fetchAndActivate()
        val fetchTime = rc.info.fetchTimeMillis
        clock.advance(1.minutes)

        worker.override = response
        assertFailsWithCode(code) { rc.fetchAndActivate() }
        assertEquals(FetchStatus.FAILURE, rc.info.lastFetchStatus)
        assertEquals(fetchTime, rc.info.fetchTimeMillis)
        assertEquals("Hello", rc.getString("welcome"))
    }

    @Test
    fun `failures - 500 gives failure status, active config untouched`() =
        failureCase(Code.SERVER_ERROR) { HttpResponse(500, emptyMap(), """{"error":"invalid_config"}""".toByteArray()) }

    @Test
    fun `failures - 401 gives failure status, active config untouched`() =
        failureCase(Code.UNAUTHORIZED) { HttpResponse(401, emptyMap()) }

    @Test
    fun `failures - bad json gives failure status, active config untouched`() =
        failureCase(Code.INVALID_RESPONSE) { HttpResponse(200, emptyMap(), "oops".toByteArray()) }

    @Test
    fun `failures - network gives failure status, active config untouched`() =
        failureCase(Code.NETWORK_ERROR) { throw IOException("offline") }

    @Test
    fun `failures - timeout gives failure`() = runTest {
        val rc = create(transport = transport { awaitCancellation() })
        rc.setConfigSettings(RemoteConfigSettings(fetchTimeout = 20.milliseconds, minimumFetchInterval = Duration.ZERO))
        assertFailsWithCode(Code.TIMEOUT) { rc.fetch() }
        assertEquals(FetchStatus.FAILURE, rc.info.lastFetchStatus)
    }

    // --- throttling ---

    @Test
    fun `throttling - 429 sets throttle and blocks fetches until it ends`() = runTest {
        val rc = ready()
        worker.override = { HttpResponse(429, mapOf("retry-after" to "30")) }
        assertFailsWithCode(Code.THROTTLED) { rc.fetch() }
        assertEquals(FetchStatus.THROTTLED, rc.info.lastFetchStatus)
        assertEquals(1, worker.requests.size)

        worker.override = null
        clock.advance(29.seconds)
        val e = assertFailsWithCode(Code.THROTTLED) { rc.fetch() }
        assertEquals(clock.now + 1_000, e.throttleEndTimeMillis)
        assertEquals(1, worker.requests.size, "no network while throttled")

        clock.advance(1.seconds)
        rc.fetch()
        assertEquals(FetchStatus.SUCCESS, rc.info.lastFetchStatus)
        assertEquals(2, worker.requests.size)
    }

    @Test
    fun `throttling - the throttle survives restarts`() = runTest {
        val rc1 = ready()
        worker.override = { HttpResponse(429, mapOf("Retry-After" to "30")) }
        assertFailsWithCode(Code.THROTTLED) { rc1.fetch() }
        worker.override = null

        val rc2 = create()
        val e = assertFailsWithCode(Code.THROTTLED) { rc2.fetch() }
        assertEquals(START + 30_000, e.throttleEndTimeMillis)
        assertEquals(1, worker.requests.size)
    }

    // --- concurrency ---

    @Test
    fun `concurrency - concurrent fetches share one request`() = runTest {
        val gate = CompletableDeferred<Unit>()
        var calls = 0
        val rc = create(
            transport = transport { request ->
                calls++
                gate.await()
                worker.handle(request)
            },
        )
        rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval = Duration.ZERO))

        val a = async { rc.fetch() }
        val b = async { rc.fetch() }
        val activated = async { rc.fetchAndActivate() }
        runCurrent()
        gate.complete(Unit)
        awaitAll(a, b)
        assertTrue(activated.await())
        assertEquals(1, calls)

        rc.fetch() // A new fetch after completion hits the network again.
        assertEquals(2, calls)
    }

    @Test
    fun `concurrency - concurrent failing fetches all throw`() = runTest {
        val rc = ready()
        worker.override = { HttpResponse(500, emptyMap()) }
        val a = async { runCatching { rc.fetch() } }
        val b = async { runCatching { rc.fetch() } }
        assertIs<RemoteConfigException>(a.await().exceptionOrNull())
        assertIs<RemoteConfigException>(b.await().exceptionOrNull())
        assertEquals(1, worker.requests.size)
    }

    @Test
    fun `concurrency - cancelling one caller does not cancel the shared fetch`() = runTest {
        val gate = CompletableDeferred<Unit>()
        var calls = 0
        val rc = create(
            transport = transport { request ->
                calls++
                gate.await()
                worker.handle(request)
            },
        )
        rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval = Duration.ZERO))

        val a = async { rc.fetch() }
        val b = async { rc.fetch() }
        runCurrent()
        a.cancel()
        gate.complete(Unit)
        b.await()

        assertTrue(a.isCancelled)
        assertEquals(1, calls)
        assertEquals(FetchStatus.SUCCESS, rc.info.lastFetchStatus)
        assertTrue(rc.activate())
    }

    @Test
    fun `concurrency - a cancelled caller gets a CancellationException, not a RemoteConfigException`() = runTest {
        val rc = create(transport = transport { awaitCancellation() })
        rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval = Duration.ZERO))
        val caller = async { rc.fetch() }
        runCurrent()
        caller.cancel()
        assertIs<CancellationException>(runCatching { caller.await() }.exceptionOrNull())
        assertEquals(FetchStatus.NO_FETCH_YET, rc.info.lastFetchStatus, "the shared fetch is still running")
    }

    // --- persistence ---

    @Test
    fun `persistence - active, pending, settings and status survive restarts`() = runTest {
        val rc1 = ready(interval = 1.hours)
        rc1.fetchAndActivate()
        worker.entries = mapOf("welcome" to "Pending")
        clock.advance(1.hours)
        rc1.fetch()

        val rc2 = create()
        rc2.ensureInitialized()
        assertEquals("Hello", rc2.getString("welcome"))
        assertEquals(1.hours, rc2.info.configSettings.minimumFetchInterval)
        assertEquals(FetchStatus.SUCCESS, rc2.info.lastFetchStatus)
        assertEquals(clock.now, rc2.info.fetchTimeMillis)

        // Pending config from rc1 can be activated after restart.
        assertTrue(rc2.activate())
        assertEquals("Pending", rc2.getString("welcome"))

        // minimumFetchInterval is honoured across restarts.
        rc2.fetch()
        assertEquals(2, worker.requests.size)
    }

    @Test
    fun `persistence - ETag survives restarts`() = runTest {
        val rc1 = ready()
        rc1.fetchAndActivate()
        val rc2 = create()
        rc2.fetch()
        assertEquals("\"${worker.version}\"", worker.requests.last().headers["If-None-Match"])
    }

    @Test
    fun `persistence - templates and endpoints are stored separately`() = runTest {
        val rc1 = ready()
        rc1.fetchAndActivate()
        val other = create(template = "staging")
        other.ensureInitialized()
        assertEquals(ValueSource.STATIC, other.getValue("welcome").source)
        other.setConfigSettings(RemoteConfigSettings())
        assertEquals(
            setOf("cloudflare_worker_kv:$ENDPOINT|default", "cloudflare_worker_kv:$ENDPOINT|staging"),
            storage.data.keys,
        )
        assertEquals(Duration.ZERO, rc1.info.configSettings.minimumFetchInterval)
    }

    private fun corruptCacheCase(corrupt: String) = runTest {
        storage = InMemoryConfigStorage(mapOf(cacheKey to corrupt))
        val rc = create()
        rc.ensureInitialized()
        assertTrue(rc.getAll().isEmpty())
        assertEquals(FetchStatus.NO_FETCH_YET, rc.info.lastFetchStatus)
        assertEquals(RemoteConfigSettings(), rc.info.configSettings)
        assertEquals(1, logger.warnings.size, "the ignored cache is logged")
        assertFalse(logger.warnings.single().first.contains(corrupt), "the log does not quote the cache")
        rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval = Duration.ZERO))
        assertTrue(rc.fetchAndActivate())
    }

    @Test
    fun `persistence - corrupt cache is ignored - not json`() = corruptCacheCase("not json")

    @Test
    fun `persistence - corrupt cache is ignored - array`() = corruptCacheCase("[]")

    @Test
    fun `persistence - corrupt cache is ignored - formatVersion 99`() = corruptCacheCase("""{"formatVersion":99}""")

    @Test
    fun `persistence - corrupt cache is ignored - malformed active snapshot`() =
        corruptCacheCase("""{"formatVersion":1,"active":{"entries":"nope"}}""")

    @Test
    fun `persistence - storage failures never break fetch and activate`() = runTest {
        val rc = create(storageOverride = ThrowingStorage())
        rc.ensureInitialized()
        rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval = Duration.ZERO))
        assertTrue(rc.fetchAndActivate())
        assertEquals("Hello", rc.getString("welcome"))
        assertTrue(logger.warnings.any { it.first.contains("read") && it.second is IllegalStateException })
        assertTrue(logger.warnings.any { it.first.contains("write") && it.second is IllegalStateException })
    }

    @Test
    fun `persistence - a failed commit is logged and the fetch still succeeds`() = runTest {
        val preferences = FakeSharedPreferences(commitResult = false)
        val rc = create(storageOverride = SharedPreferencesConfigStorage(preferences))
        rc.ensureInitialized()
        rc.setConfigSettings(RemoteConfigSettings(minimumFetchInterval = Duration.ZERO))
        assertTrue(rc.fetchAndActivate())
        assertEquals("Hello", rc.getString("welcome"))
        assertTrue(preferences.values.isEmpty())
        assertTrue(logger.warnings.isNotEmpty())
        assertTrue(logger.warnings.all { it.first.contains("write") && it.second is IOException })
    }

    @Test
    fun `persistence - last write wins when writes overlap`() = runTest {
        val slow = SlowStorage()
        val rc2 = create(storageOverride = slow)
        rc2.ensureInitialized()
        rc2.setConfigSettings(RemoteConfigSettings(minimumFetchInterval = Duration.ZERO))
        rc2.fetch()
        slow.resetDelays()

        // Two persists in flight at once; the first is the slowest.
        val newSettings = RemoteConfigSettings(minimumFetchInterval = 5.minutes)
        awaitAll(async { rc2.activate() }, async { rc2.setConfigSettings(newSettings) })

        val saved = Json.parseToJsonElement(slow.data.values.single()).jsonObject
        assertNotEquals(JsonNull, saved["active"])
        assertEquals(JsonNull, saved["fetched"])
        assertEquals(newSettings, settingsFromJson(saved["settings"]))
    }

    @Test
    fun `persistence - the cache uses the shared format`() = runTest {
        val rc = ready(interval = 1.hours)
        rc.fetchAndActivate()
        val saved = Json.parseToJsonElement(storage.data.getValue(cacheKey)).jsonObject
        val expected = buildJsonObject {
            put("formatVersion", 1)
            put(
                "active",
                buildJsonObject {
                    put("version", worker.version)
                    put("entries", buildJsonObject { worker.entries.forEach { (k, v) -> put(k, v) } })
                },
            )
            put("fetched", JsonNull)
            put("etag", "\"${worker.version}\"")
            put("lastSuccessfulFetchMs", START)
            put("throttleEndMs", JsonNull)
            put("lastFetchStatus", "success")
            put(
                "settings",
                buildJsonObject {
                    put("fetchTimeoutMs", 60_000)
                    put("minimumFetchIntervalMs", 3_600_000)
                },
            )
        }
        assertEquals(expected, saved)
    }

    @Test
    fun `persistence - reads the cache example from the spec`() = runTest {
        val raw = """
            {
              "formatVersion": 1,
              "active": {"version": "v1", "entries": {"k": "v"}},
              "fetched": null,
              "etag": "\"v1\"",
              "lastSuccessfulFetchMs": 1767225600000,
              "throttleEndMs": null,
              "lastFetchStatus": "success",
              "settings": {"fetchTimeoutMs": 60000, "minimumFetchIntervalMs": 43200000}
            }
        """.trimIndent()
        storage = InMemoryConfigStorage(mapOf(cacheKey to raw))
        val rc = create()
        rc.ensureInitialized()
        assertEquals(RemoteConfigValue("v", ValueSource.REMOTE), rc.getValue("k"))
        assertEquals(1_767_225_600_000L, rc.info.fetchTimeMillis)
        assertEquals(FetchStatus.SUCCESS, rc.info.lastFetchStatus)
        assertEquals(RemoteConfigSettings(), rc.info.configSettings)
        rc.fetch()
        assertTrue(worker.requests.isEmpty(), "inside the 12 hour interval")
        assertTrue(logger.warnings.isEmpty())
    }

    @Test
    fun `persistence - invalid fields fall back to their defaults`() = runTest {
        val raw = """
            {"formatVersion":1,"active":null,"fetched":null,"etag":5,"lastSuccessfulFetchMs":"1767225600000",
             "throttleEndMs":1.5,"lastFetchStatus":"weird","settings":{"fetchTimeoutMs":0,"minimumFetchIntervalMs":1}}
        """.trimIndent()
        storage = InMemoryConfigStorage(mapOf(cacheKey to raw))
        val rc = create()
        rc.ensureInitialized()
        assertEquals(-1L, rc.info.fetchTimeMillis)
        assertEquals(FetchStatus.NO_FETCH_YET, rc.info.lastFetchStatus)
        assertEquals(RemoteConfigSettings(), rc.info.configSettings)
        rc.fetch() // Not throttled, not inside an interval.
        assertNull(worker.requests.single().headers["If-None-Match"])
    }

    // --- singleton ---

    @Test
    fun `singleton - instance throws before initialize`() {
        assertFailsWith<IllegalStateException> { CloudflareRemoteConfig.instance }
    }

    @Test
    fun `singleton - initialize loads cache and exposes instance`() = runTest {
        val rc1 = ready()
        rc1.fetchAndActivate()

        val rc = CloudflareRemoteConfig.install(create())
        assertSame(rc, CloudflareRemoteConfig.instance)
        assertEquals("Hello", rc.getString("welcome")) // No await needed.
    }

    @Test
    fun `singleton - initialize disposes the previous instance`() = runTest {
        val gate = CompletableDeferred<Unit>()
        val first = CloudflareRemoteConfig.install(
            create(
                transport = transport { request ->
                    gate.await()
                    worker.handle(request)
                },
            ),
        )
        first.setConfigSettings(RemoteConfigSettings(minimumFetchInterval = Duration.ZERO))
        val cacheBefore = storage.data
        val pending = async { runCatching { first.fetch() } }
        runCurrent()

        val second = CloudflareRemoteConfig.install(create())
        assertSame(second, CloudflareRemoteConfig.instance)
        gate.complete(Unit)

        assertIs<IllegalStateException>(pending.await().exceptionOrNull())
        assertFailsWith<IllegalStateException> { first.fetch() }
        first.setConfigSettings(RemoteConfigSettings(minimumFetchInterval = 1.hours))
        assertEquals(cacheBefore, storage.data, "a disposed instance no longer writes the cache")
        assertEquals(RemoteConfigValue(null, ValueSource.STATIC), first.getValue("welcome"))
        assertTrue(second.fetchAndActivate())
    }

    @Test
    fun `singleton - resetInstance clears the instance`() = runTest {
        CloudflareRemoteConfig.install(create())
        CloudflareRemoteConfig.resetInstance()
        assertFailsWith<IllegalStateException> { CloudflareRemoteConfig.instance }
    }

    @Test
    fun `info - reports the settings`() = runTest {
        val rc = ready()
        val settings = RemoteConfigSettings(minimumFetchInterval = Duration.ZERO)
        assertEquals(settings, rc.info.configSettings)
        assertEquals(
            "RemoteConfigInfo(fetchTimeMillis=-1, lastFetchStatus=NO_FETCH_YET, configSettings=$settings)",
            rc.info.toString(),
        )
    }

    private companion object {
        const val ENDPOINT = "https://cfg.example.com"
        const val START = 1_767_225_600_000L
    }
}
