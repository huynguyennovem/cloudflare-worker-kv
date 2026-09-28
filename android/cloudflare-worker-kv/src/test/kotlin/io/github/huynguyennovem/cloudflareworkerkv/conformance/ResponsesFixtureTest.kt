package io.github.huynguyennovem.cloudflareworkerkv.conformance

import io.github.huynguyennovem.cloudflareworkerkv.Clock
import io.github.huynguyennovem.cloudflareworkerkv.HttpResponse
import io.github.huynguyennovem.cloudflareworkerkv.RemoteConfigException
import io.github.huynguyennovem.cloudflareworkerkv.WorkerClient
import io.github.huynguyennovem.cloudflareworkerkv.WorkerFetchResult
import io.github.huynguyennovem.cloudflareworkerkv.helpers.SpecFixtures
import io.github.huynguyennovem.cloudflareworkerkv.helpers.transport
import io.github.huynguyennovem.cloudflareworkerkv.stringOrNull
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/** Runs every case of spec/fixtures/responses.json (spec §2.3) through the Worker client. */
@RunWith(Parameterized::class)
class ResponsesFixtureTest(
    @Suppress("unused") private val name: String,
    private val case: JsonObject,
) {
    @Test
    fun mapsTheResponse() = runTest {
        val status = case.getValue("status").jsonPrimitive.int
        val headers = case.getValue("headers").jsonObject.mapValues { it.value.jsonPrimitive.content }
        val body = case.getValue("body").jsonPrimitive.content.toByteArray(Charsets.UTF_8)
        val sentEtag = case["sentEtag"].stringOrNull()
        val expect = case.getValue("expect").jsonObject

        val client = WorkerClient(
            endpoint = "https://cfg.example.com",
            template = "default",
            clientKey = null,
            transport = transport { request ->
                assertEquals(sentEtag, request.headers["If-None-Match"])
                HttpResponse(status, headers, body)
            },
            clock = Clock { NOW },
        )
        val outcome = runCatching { client.fetch(sentEtag, 5.seconds) }

        when {
            expect["result"].stringOrNull() == "fetched" -> {
                if (expect.keys != setOf("result", "version", "etag", "entries")) fail("Unknown expect shape: $expect")
                val fetched = assertIs<WorkerFetchResult.Fetched>(outcome.getOrThrow())
                assertEquals(expect["version"].stringOrNull(), fetched.snapshot.version)
                assertEquals(expect["etag"].stringOrNull(), fetched.etag)
                assertEquals(
                    expect.getValue("entries").jsonObject.mapValues { it.value.jsonPrimitive.content },
                    fetched.snapshot.entries,
                )
            }
            expect["result"].stringOrNull() == "notModified" -> {
                if (expect.keys != setOf("result")) fail("Unknown expect shape: $expect")
                assertSame(WorkerFetchResult.NotModified, outcome.getOrThrow())
            }
            expect["error"] != null -> {
                val known = setOf("error", "statusCode", "throttleSeconds", "messageContains")
                if (!known.containsAll(expect.keys) || "statusCode" !in expect) fail("Unknown expect shape: $expect")
                val e = assertIs<RemoteConfigException>(outcome.exceptionOrNull(), "expected an error, got $outcome")
                assertEquals(expect["error"].stringOrNull(), e.code.value)
                assertEquals(expect.getValue("statusCode").jsonPrimitive.int, e.statusCode)
                val throttleSeconds = expect["throttleSeconds"]?.jsonPrimitive?.long
                if (throttleSeconds == null) {
                    assertNull(e.throttleEndTimeMillis)
                } else {
                    assertEquals(NOW + throttleSeconds * 1000, e.throttleEndTimeMillis)
                }
                expect["messageContains"]?.let { fragment ->
                    val text = fragment.jsonPrimitive.content
                    assertTrue(e.message.contains(text), "\"${e.message}\" should contain \"$text\"")
                }
            }
            else -> fail("Unknown expect shape: $expect")
        }
    }

    companion object {
        /** 2026-01-01T00:00:00Z, the fixed request time. */
        private const val NOW = 1_767_225_600_000L

        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun cases(): List<Array<Any>> =
            SpecFixtures.cases("responses.json").map { arrayOf(it.getValue("name").jsonPrimitive.content, it) }
    }
}
