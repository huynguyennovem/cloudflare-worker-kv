package io.github.huynguyennovem.cloudflareworkerkv.helpers

import io.github.huynguyennovem.cloudflareworkerkv.HttpRequest
import io.github.huynguyennovem.cloudflareworkerkv.HttpResponse
import io.github.huynguyennovem.cloudflareworkerkv.HttpTransport
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/** Simulates the config Worker's HTTP contract in memory (port of fake_worker.dart). */
internal class FakeWorker(
    entries: Map<String, String> = emptyMap(),
    /** When set, requests must send a matching `X-Client-Key`. */
    var clientKey: String? = null,
) : HttpTransport {
    /** Current config served by the fake Worker. */
    var entries: Map<String, String> = LinkedHashMap(entries)

    /** When set, returned instead of the normal response. */
    var override: (suspend (HttpRequest) -> HttpResponse)? = null

    /** Every request received, in order. */
    val requests: MutableList<HttpRequest> = CopyOnWriteArrayList()

    val version: String
        get() {
            val pairs = entries.keys.sorted().map { key ->
                JsonArray(listOf(JsonPrimitive(key), JsonPrimitive(entries.getValue(key))))
            }
            return Base64.getUrlEncoder().encodeToString(JsonArray(pairs).toString().toByteArray())
        }

    override suspend fun execute(request: HttpRequest): HttpResponse = handle(request)

    /** Handles one request like the real Worker would. */
    suspend fun handle(request: HttpRequest): HttpResponse {
        requests += request
        override?.let { return it(request) }
        if (clientKey != null && request.headers["X-Client-Key"] != clientKey) {
            return HttpResponse(401, emptyMap(), """{"error":"unauthorized"}""".toByteArray())
        }
        val etag = "\"$version\""
        if (request.headers["If-None-Match"] == etag) {
            return HttpResponse(304, mapOf("etag" to etag))
        }
        val body = buildJsonObject {
            put("version", version)
            putJsonObject("entries") { for ((key, value) in entries) put(key, value) }
        }.toString()
        return HttpResponse(
            200,
            mapOf("etag" to etag, "content-type" to "application/json"),
            body.toByteArray(Charsets.UTF_8),
        )
    }
}

/** An [HttpTransport] backed by [handler]. */
internal fun transport(handler: suspend (HttpRequest) -> HttpResponse): HttpTransport = object : HttpTransport {
    override suspend fun execute(request: HttpRequest): HttpResponse = handler(request)
}
