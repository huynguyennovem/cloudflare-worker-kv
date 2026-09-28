package io.github.huynguyennovem.cloudflareworkerkv

import io.github.huynguyennovem.cloudflareworkerkv.RemoteConfigException.Code
import io.github.huynguyennovem.cloudflareworkerkv.helpers.RecordingLogger
import io.github.huynguyennovem.cloudflareworkerkv.helpers.SpecFixtures
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.SocketEffect

/** The default transport against a real HTTP server (real time, no virtual clock). */
class HttpUrlConnectionTransportTest {
    private val server = MockWebServer()
    private val transport = HttpUrlConnectionTransport()

    @BeforeTest
    fun setUp() {
        server.start()
    }

    @AfterTest
    fun tearDown() {
        server.close()
    }

    private fun request(path: String = "/v1/config?template=default", headers: Map<String, String> = emptyMap()) =
        HttpRequest(server.url(path).toString(), headers, 5.seconds)

    private fun response(code: Int, body: String = "", vararg headers: Pair<String, String>): MockResponse =
        MockResponse.Builder().code(code).body(body).apply {
            headers.forEach { (name, value) -> addHeader(name, value) }
        }.build()

    @Test
    fun `sends a GET with the given headers`() = runBlocking {
        server.enqueue(response(200, "{}"))
        transport.execute(
            request(headers = mapOf("Accept" to "application/json", "X-Client-Key" to "k", "If-None-Match" to "\"v1\"")),
        )
        val recorded = server.takeRequest()
        assertEquals("GET", recorded.method)
        assertEquals("/v1/config?template=default", recorded.target)
        assertEquals("application/json", recorded.headers["Accept"])
        assertEquals("k", recorded.headers["X-Client-Key"])
        assertEquals("\"v1\"", recorded.headers["If-None-Match"])
    }

    @Test
    fun `returns the 200 body and case-insensitive headers`() = runBlocking {
        server.enqueue(response(200, """{"entries":{"a":"xin chào"}}""", "ETag" to "\"v1\"", "X-Multi" to "a", "X-Multi" to "b"))
        val result = transport.execute(request())
        assertEquals(200, result.statusCode)
        assertEquals("""{"entries":{"a":"xin chào"}}""", result.body.toString(Charsets.UTF_8))
        assertEquals("\"v1\"", result.header("etag"))
        assertEquals("\"v1\"", result.headers["ETAG"])
        assertEquals(setOf("a", "b"), result.header("x-multi")!!.split(", ").toSet())
        assertEquals("OK", result.reasonPhrase)
    }

    @Test
    fun `reads the body of an error response`() = runBlocking {
        server.enqueue(response(503, """{"error":"kv_unavailable"}"""))
        val result = transport.execute(request())
        assertEquals(503, result.statusCode)
        assertEquals("""{"error":"kv_unavailable"}""", result.body.toString(Charsets.UTF_8))
    }

    @Test
    fun `returns 304 with an empty body`() = runBlocking {
        server.enqueue(response(304, "", "ETag" to "\"v1\""))
        val result = transport.execute(request(headers = mapOf("If-None-Match" to "\"v1\"")))
        assertEquals(304, result.statusCode)
        assertContentEquals(ByteArray(0), result.body)
    }

    @Test
    fun `follows redirects`() = runBlocking {
        server.enqueue(response(302, "", "Location" to "/moved"))
        server.enqueue(response(200, "moved"))
        val result = transport.execute(request())
        assertEquals(200, result.statusCode)
        assertEquals("moved", result.body.toString(Charsets.UTF_8))
        assertEquals("/v1/config?template=default", server.takeRequest().target)
        assertEquals("/moved", server.takeRequest().target)
    }

    @Test
    fun `connection refused throws an IOException`() = runBlocking {
        val closed = MockWebServer().apply { start() }
        val url = closed.url("/v1/config").toString()
        closed.close()
        assertFailsWith<IOException> { transport.execute(HttpRequest(url, emptyMap(), 5.seconds)) }
        Unit
    }

    @Test
    fun `stalled headers fail with a timeout within the fetch timeout`() = runBlocking {
        server.enqueue(MockResponse.Builder().onResponseStart(SocketEffect.Stall).build())
        val client = WorkerClient(server.url("/").toString(), "default", null, transport, Clock.SYSTEM)
        val mark = TimeSource.Monotonic.markNow()
        val e = assertFailsWith<RemoteConfigException> { client.fetch(null, 300.milliseconds) }
        val elapsed = mark.elapsedNow()
        assertEquals(Code.TIMEOUT, e.code)
        assertTrue(elapsed < 2.seconds, "took $elapsed")
    }

    @Test
    fun `a trickling body is cut off by the whole-request timeout`() = runBlocking {
        // One byte every 100 ms never trips the per-read timeout, only the total one.
        server.enqueue(
            MockResponse.Builder().code(200).body("x".repeat(64)).throttleBody(1, 100, TimeUnit.MILLISECONDS).build(),
        )
        val client = WorkerClient(server.url("/").toString(), "default", null, transport, Clock.SYSTEM)
        val mark = TimeSource.Monotonic.markNow()
        val e = assertFailsWith<RemoteConfigException> { client.fetch(null, 500.milliseconds) }
        val elapsed = mark.elapsedNow()
        assertEquals(Code.TIMEOUT, e.code)
        assertTrue(elapsed < 2.seconds, "took $elapsed")
    }

    @Test
    fun `end-to-end fetchAndActivate`() = runBlocking {
        val rc = CloudflareRemoteConfig(
            endpoint = server.url("/api/").toString(),
            template = "staging",
            clientKey = "k",
            transport = transport,
            storage = InMemoryConfigStorage(),
            clock = Clock.SYSTEM,
            logger = RecordingLogger(),
            coroutineContext = Dispatchers.Default,
        )
        try {
            rc.setConfigSettings(RemoteConfigSettings(fetchTimeout = 5.seconds, minimumFetchInterval = Duration.ZERO))
            server.enqueue(
                response(
                    200,
                    """{"version":"v1","entries":{"welcome":"Hello from KV","max_items":"7"}}""",
                    "ETag" to "\"v1\"",
                    "Content-Type" to "application/json; charset=utf-8",
                ),
            )
            assertTrue(rc.fetchAndActivate())
            assertEquals("Hello from KV", rc.getString("welcome"))
            assertEquals(7L, rc.getLong("max_items"))
            val first = server.takeRequest()
            assertEquals("/api/v1/config?template=staging", first.target)
            assertEquals("k", first.headers["X-Client-Key"])
            assertNull(first.headers["If-None-Match"])

            server.enqueue(response(304, "", "ETag" to "\"v1\""))
            assertFalse(rc.fetchAndActivate())
            assertEquals("\"v1\"", server.takeRequest().headers["If-None-Match"])
            assertEquals(FetchStatus.SUCCESS, rc.info.lastFetchStatus)
        } finally {
            rc.dispose()
        }
    }

    @Test
    fun `every responses fixture case over real HTTP`() = runBlocking {
        val failures = mutableListOf<String>()
        for (case in SpecFixtures.cases("responses.json")) {
            val name = case.getValue("name").jsonPrimitive.content
            val headers = case.getValue("headers").jsonObject.map { (k, v) -> k to v.jsonPrimitive.content }
            server.enqueue(
                response(case.getValue("status").jsonPrimitive.int, case.getValue("body").jsonPrimitive.content, *headers.toTypedArray()),
            )
            val sentEtag = case["sentEtag"].stringOrNull()
            val client = WorkerClient(server.url("/").toString(), "default", null, transport, Clock.SYSTEM)
            val outcome = runCatching { client.fetch(sentEtag, 5.seconds) }
            val expect = case.getValue("expect").jsonObject
            val actual = when (val value = outcome.getOrNull()) {
                is WorkerFetchResult.Fetched -> "fetched ${value.snapshot.entries}"
                WorkerFetchResult.NotModified -> "notModified"
                null -> (outcome.exceptionOrNull() as? RemoteConfigException)?.code?.value ?: "$outcome"
            }
            val wanted = when (expect["result"].stringOrNull()) {
                "fetched" -> "fetched " + expect.getValue("entries").jsonObject.mapValues { it.value.jsonPrimitive.content }
                "notModified" -> "notModified"
                else -> expect["error"].stringOrNull()
            }
            if (actual != wanted) failures += "$name: expected $wanted, got $actual"
        }
        assertTrue(failures.isEmpty(), failures.joinToString("\n"))
    }
}
