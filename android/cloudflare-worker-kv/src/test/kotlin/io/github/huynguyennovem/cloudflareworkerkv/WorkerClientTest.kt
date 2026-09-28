@file:OptIn(ExperimentalCoroutinesApi::class)

package io.github.huynguyennovem.cloudflareworkerkv

import io.github.huynguyennovem.cloudflareworkerkv.RemoteConfigException.Code
import io.github.huynguyennovem.cloudflareworkerkv.helpers.START_MILLIS
import io.github.huynguyennovem.cloudflareworkerkv.helpers.transport
import java.io.IOException
import java.net.SocketTimeoutException
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** Port of flutter/test/worker_client_test.dart, plus Kotlin-specific cases. */
class WorkerClientTest {
    private val timeout = 5.seconds

    private fun clientFor(transport: HttpTransport, clientKey: String? = null) =
        WorkerClient(ENDPOINT, "default", clientKey, transport, Clock { START_MILLIS })

    private fun respond(status: Int, body: String = "", headers: Map<String, String> = emptyMap()) =
        clientFor(transport { HttpResponse(status, headers, body.toByteArray()) })

    private inline fun assertFailsWithCode(code: Code, status: Int? = null, block: () -> Unit): RemoteConfigException {
        val e = assertFailsWith<RemoteConfigException> { block() }
        assertEquals(code, e.code, e.toString())
        assertEquals(status, e.statusCode, e.toString())
        return e
    }

    // --- buildConfigUri ---

    @Test
    fun `buildConfigUri - appends path and template`() {
        assertEquals("https://a.dev/v1/config?template=default", ConfigUri.build("https://a.dev", "default"))
    }

    @Test
    fun `buildConfigUri - preserves path prefix, query and drops fragment`() {
        assertEquals(
            "https://a.dev/api/v1/config?x=1&template=staging",
            ConfigUri.build("https://a.dev/api/?x=1#frag", "staging"),
        )
    }

    @Test
    fun `buildConfigUri - keeps a custom port`() {
        assertEquals(
            "https://config.example.com:8443/v1/config?template=d",
            ConfigUri.build("https://config.example.com:8443", "d"),
        )
    }

    @Test
    fun `buildConfigUri - rejects relative URLs`() {
        assertFailsWith<IllegalArgumentException> { ConfigUri.build("/config", "d") }
    }

    @Test
    fun `buildConfigUri - accepts host names with an underscore`() {
        assertEquals(
            "https://my_worker.example.dev/v1/config?template=d",
            ConfigUri.build("https://my_worker.example.dev", "d"),
        )
    }

    @Test
    fun `buildConfigUri - rejects an authority without a host`() {
        for (endpoint in listOf("https://:8080", "https://user@", "https://user@:1", "http://[]/")) {
            assertFailsWith<IllegalArgumentException>(endpoint) { ConfigUri.build(endpoint, "d") }
        }
    }

    @Test
    fun `buildConfigUri - query parameters follow Dart semantics`() {
        assertEquals(
            "https://a.dev/v1/config?a=2&b&template=t",
            ConfigUri.build("https://a.dev/?a=1&&b=&=x&a=2", "t"),
        )
    }

    // --- fetch ---

    @Test
    fun `sends headers and parses 200`() = runTest {
        lateinit var seen: HttpRequest
        val client = clientFor(
            transport { request ->
                seen = request
                HttpResponse(
                    200,
                    mapOf("etag" to "\"v1\""),
                    """{"version":"v1","entries":{"a":"xin chào","n":1,"b":true,"o":{"k":1},"z":null}}"""
                        .toByteArray(Charsets.UTF_8),
                )
            },
            clientKey = "secret",
        )

        val result = client.fetch(etag = "\"v0\"", timeout = timeout)

        assertEquals("https://cfg.example.com/v1/config?template=default", seen.url)
        assertEquals(
            mapOf("Accept" to "application/json", "X-Client-Key" to "secret", "If-None-Match" to "\"v0\""),
            seen.headers,
        )
        assertEquals(timeout, seen.timeout)
        val fetched = assertIs<WorkerFetchResult.Fetched>(result)
        assertEquals("\"v1\"", fetched.etag)
        assertEquals("v1", fetched.snapshot.version)
        assertEquals(mapOf("a" to "xin chào", "n" to "1", "b" to "true", "o" to """{"k":1}"""), fetched.snapshot.entries)
    }

    @Test
    fun `omits optional headers when not provided`() = runTest {
        lateinit var seen: HttpRequest
        val client = clientFor(
            transport { request ->
                seen = request
                HttpResponse(200, emptyMap(), """{"version":"v","entries":{}}""".toByteArray())
            },
        )
        client.fetch(etag = null, timeout = timeout)
        assertEquals(mapOf("Accept" to "application/json"), seen.headers)
    }

    @Test
    fun `falls back to ETag when version is missing`() = runTest {
        val client = respond(200, """{"entries":{}}""", mapOf("etag" to "W/\"abc\""))
        val result = assertIs<WorkerFetchResult.Fetched>(client.fetch(null, timeout))
        assertEquals("abc", result.snapshot.version)
    }

    @Test
    fun `304 with etag gives not modified`() = runTest {
        assertSame(WorkerFetchResult.NotModified, respond(304).fetch("\"v\"", timeout))
    }

    @Test
    fun `304 without etag gives invalid-response`() = runTest {
        assertFailsWithCode(Code.INVALID_RESPONSE, 304) { respond(304).fetch(null, timeout) }
    }

    @Test
    fun `malformed bodies give invalid-response`() = runTest {
        val bodies = listOf(
            "not json", "[]", """{"entries":[]}""", "{}", "null",
            // Kotlin-specific: strict JSON only.
            "{entries:{}}", """{"entries":{"a":abc}}""", """{"entries":{"a":01}}""", """{"entries":{},}""",
            """{'entries':{}}""", "[".repeat(600) + "]".repeat(600),
        )
        for (body in bodies) {
            assertFailsWithCode(Code.INVALID_RESPONSE, 200) { respond(200, body).fetch(null, timeout) }
        }
    }

    @Test
    fun `invalid UTF-8 gives invalid-response`() = runTest {
        val client = clientFor(transport { HttpResponse(200, emptyMap(), byteArrayOf(0x7B, 0xC3.toByte(), 0x28, 0x7D)) })
        assertFailsWithCode(Code.INVALID_RESPONSE, 200) { client.fetch(null, timeout) }
    }

    @Test
    fun `401 and 403 give unauthorized`() = runTest {
        for (status in listOf(401, 403)) {
            assertFailsWithCode(Code.UNAUTHORIZED, status) { respond(status).fetch(null, timeout) }
        }
    }

    @Test
    fun `429 gives throttled with Retry-After`() = runTest {
        val e = assertFailsWithCode(Code.THROTTLED, 429) {
            respond(429, headers = mapOf("retry-after" to "120")).fetch(null, timeout)
        }
        assertEquals(START_MILLIS + 120_000, e.throttleEndTimeMillis)
    }

    @Test
    fun `429 without Retry-After uses default duration`() = runTest {
        val e = assertFailsWithCode(Code.THROTTLED, 429) { respond(429).fetch(null, timeout) }
        assertEquals(START_MILLIS + WorkerClient.DEFAULT_THROTTLE_DURATION.inWholeMilliseconds, e.throttleEndTimeMillis)
    }

    @Test
    fun `Retry-After takes ASCII digits only and saturates`() {
        val default = WorkerClient.DEFAULT_THROTTLE_DURATION.inWholeMilliseconds
        assertEquals(0L, WorkerClient.parseRetryAfterMillis("0"))
        assertEquals(30_000L, WorkerClient.parseRetryAfterMillis("\t30 "))
        for (header in listOf(null, "", " ", "+5", "-5", "1.5", "0x10", "٣", "Wed, 21 Oct 2026 07:28:00 GMT")) {
            assertEquals(default, WorkerClient.parseRetryAfterMillis(header), "$header")
        }
        assertEquals(Long.MAX_VALUE, WorkerClient.parseRetryAfterMillis("99999999999999999999999"))
        assertEquals(Long.MAX_VALUE, WorkerClient.saturatedAdd(START_MILLIS, Long.MAX_VALUE))
    }

    @Test
    fun `5xx gives server-error with worker error code in message`() = runTest {
        val e = assertFailsWithCode(Code.SERVER_ERROR, 500) {
            respond(500, """{"error":"invalid_config","message":"bad"}""").fetch(null, timeout)
        }
        assertEquals("Unexpected response: invalid_config - bad", e.message)
    }

    @Test
    fun `server-error falls back to the reason phrase, then to the status`() = runTest {
        val withReason = clientFor(transport { HttpResponse(502, emptyMap(), "<html>".toByteArray(), "Bad Gateway") })
        assertEquals(
            "Unexpected response: Bad Gateway",
            assertFailsWithCode(Code.SERVER_ERROR, 502) { withReason.fetch(null, timeout) }.message,
        )
        assertEquals(
            "Unexpected response: HTTP 502",
            assertFailsWithCode(Code.SERVER_ERROR, 502) { respond(502, "<html>").fetch(null, timeout) }.message,
        )
        assertEquals(
            "Unexpected response: not_found",
            assertFailsWithCode(Code.SERVER_ERROR, 404) {
                respond(404, """{"error":"not_found","message":7}""").fetch(null, timeout)
            }.message,
        )
    }

    @Test
    fun `network error gives network-error`() = runTest {
        val client = clientFor(transport { throw IOException("offline") })
        val e = assertFailsWithCode(Code.NETWORK_ERROR) { client.fetch(null, timeout) }
        assertIs<IOException>(e.cause)
    }

    @Test
    fun `SecurityException gives network-error`() = runTest {
        // Thrown by HttpURLConnection when the app lacks the INTERNET permission.
        val client = clientFor(transport { throw SecurityException("Permission denied (missing INTERNET permission?)") })
        assertFailsWithCode(Code.NETWORK_ERROR) { client.fetch(null, timeout) }
    }

    @Test
    fun `SocketTimeoutException gives timeout`() = runTest {
        val client = clientFor(transport { throw SocketTimeoutException("Read timed out") })
        val e = assertFailsWithCode(Code.TIMEOUT) { client.fetch(null, timeout) }
        assertIs<SocketTimeoutException>(e.cause)
    }

    @Test
    fun `slow response gives timeout`() = runTest {
        val client = clientFor(transport { awaitCancellation() }) // Never completes.
        val e = assertFailsWithCode(Code.TIMEOUT) { client.fetch(null, 20.milliseconds) }
        assertEquals("No response within 20 ms.", e.message)
    }

    @Test
    fun `caller cancellation propagates instead of becoming a network error`() = runTest {
        var transportCancelled = false
        val client = clientFor(
            transport {
                try {
                    awaitCancellation()
                } finally {
                    transportCancelled = true
                }
            },
        )
        var thrown: Throwable? = null
        val job = launch {
            try {
                client.fetch(null, timeout)
            } catch (t: Throwable) {
                thrown = t
                throw t
            }
        }
        runCurrent()
        job.cancel()
        job.join()
        assertIs<CancellationException>(thrown)
        assertTrue(transportCancelled)
    }

    @Test
    fun `exception toString is informative`() {
        val e = RemoteConfigException(Code.SERVER_ERROR, "boom", statusCode = 502)
        assertEquals("RemoteConfigException[server-error] (HTTP 502): boom", e.toString())
        assertEquals(
            "RemoteConfigException[timeout]: slow",
            RemoteConfigException(Code.TIMEOUT, "slow").toString(),
        )
    }

    @Test
    fun `error codes use the shared strings`() {
        assertEquals(
            listOf("timeout", "network-error", "unauthorized", "throttled", "server-error", "invalid-response"),
            Code.entries.map { it.value },
        )
    }

    private companion object {
        const val ENDPOINT = "https://cfg.example.com"
    }
}
