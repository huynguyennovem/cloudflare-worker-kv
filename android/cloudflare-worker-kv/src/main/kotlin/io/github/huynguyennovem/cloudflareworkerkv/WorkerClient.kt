package io.github.huynguyennovem.cloudflareworkerkv

import io.github.huynguyennovem.cloudflareworkerkv.RemoteConfigException.Code
import java.net.SocketTimeoutException
import java.util.Collections
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject

/** Result of [WorkerClient.fetch]. */
internal sealed interface WorkerFetchResult {
    /** The Worker returned a (possibly unchanged) config and its `ETag`, if any. */
    class Fetched(val snapshot: ConfigSnapshot, val etag: String?) : WorkerFetchResult

    /** The Worker returned `304 Not Modified`. */
    data object NotModified : WorkerFetchResult
}

/** Low-level HTTP client for the config Worker (spec §2.1 to §2.3). */
internal class WorkerClient(
    endpoint: String,
    template: String,
    private val clientKey: String?,
    private val transport: HttpTransport,
    private val clock: Clock,
) {
    /** Fully resolved URL of the config endpoint. */
    val configUri: String = ConfigUri.build(endpoint, template)

    /**
     * Fetches the config, sending `If-None-Match: etag` when [etag] is not `null`. [timeout]
     * limits the whole request.
     *
     * @throws RemoteConfigException on any failure.
     */
    suspend fun fetch(etag: String?, timeout: Duration): WorkerFetchResult {
        val headers = LinkedHashMap<String, String>()
        headers["Accept"] = "application/json"
        if (clientKey != null) headers["X-Client-Key"] = clientKey
        if (etag != null) headers["If-None-Match"] = etag
        val request = HttpRequest(configUri, Collections.unmodifiableMap(headers), timeout)

        val response = try {
            withTimeoutOrNull(timeout) { transport.execute(request) }
        } catch (e: CancellationException) {
            throw e // The caller was cancelled: not a network error.
        } catch (e: SocketTimeoutException) {
            throw timeoutError(timeout, e)
        } catch (e: Exception) {
            throw RemoteConfigException(Code.NETWORK_ERROR, "Request to $configUri failed: $e", cause = e)
        } ?: throw timeoutError(timeout, null)

        val status = response.statusCode
        when (status) {
            304 -> {
                if (etag == null) {
                    throw RemoteConfigException(
                        Code.INVALID_RESPONSE,
                        "Received 304 for an unconditional request.",
                        statusCode = 304,
                    )
                }
                return WorkerFetchResult.NotModified
            }
            200 -> {
                val responseEtag = response.header("ETag")
                try {
                    val snapshot = ConfigSnapshot.parse(response.body, fallbackVersion = stripEtag(responseEtag))
                    return WorkerFetchResult.Fetched(snapshot, responseEtag)
                } catch (e: MalformedJsonException) {
                    throw RemoteConfigException(
                        Code.INVALID_RESPONSE,
                        "Malformed config payload: ${e.message}",
                        statusCode = status,
                        cause = e,
                    )
                }
            }
            401, 403 -> throw RemoteConfigException(
                Code.UNAUTHORIZED,
                "The Worker rejected the client key.",
                statusCode = status,
            )
            429 -> {
                val retryAfterMillis = parseRetryAfterMillis(response.header("Retry-After"))
                throw RemoteConfigException(
                    Code.THROTTLED,
                    "Fetch is rate limited.",
                    statusCode = status,
                    throttleEndTimeMillis = saturatedAdd(clock.nowMillis(), retryAfterMillis),
                )
            }
            else -> throw RemoteConfigException(
                Code.SERVER_ERROR,
                "Unexpected response: ${describeError(response)}",
                statusCode = status,
            )
        }
    }

    private fun timeoutError(timeout: Duration, cause: Throwable?) = RemoteConfigException(
        Code.TIMEOUT,
        "No response within ${timeout.inWholeMilliseconds} ms.",
        cause = cause,
    )

    internal companion object {
        /** Used when a 429 response carries no usable `Retry-After` header. */
        val DEFAULT_THROTTLE_DURATION: Duration = 1.minutes

        /**
         * `Retry-After` in milliseconds: a trimmed, non-negative decimal number of seconds
         * (saturating), otherwise [DEFAULT_THROTTLE_DURATION].
         */
        fun parseRetryAfterMillis(header: String?): Long {
            val text = header?.trim().orEmpty()
            if (text.isEmpty() || !text.all { it in '0'..'9' }) {
                return DEFAULT_THROTTLE_DURATION.inWholeMilliseconds
            }
            val seconds = text.toLongOrNull() ?: Long.MAX_VALUE
            return if (seconds > Long.MAX_VALUE / 1000) Long.MAX_VALUE else seconds * 1000
        }

        /** [time] + [delta] for a non-negative [delta], clamped to [Long.MAX_VALUE]. */
        fun saturatedAdd(time: Long, delta: Long): Long {
            val sum = time + delta
            return if (sum < time) Long.MAX_VALUE else sum
        }

        /** Removes a `W/` prefix and surrounding quotes. */
        fun stripEtag(etag: String?): String? {
            if (etag == null) return null
            var tag = etag.trim()
            if (tag.startsWith("W/")) tag = tag.substring(2)
            if (tag.length >= 2 && tag.startsWith('"') && tag.endsWith('"')) {
                tag = tag.substring(1, tag.length - 1)
            }
            return tag
        }

        /** `<error> - <message>` from a JSON error body, else the reason phrase or `HTTP n`. */
        fun describeError(response: HttpResponse): String {
            val body = try {
                parseStrictJson(String(response.body, Charsets.UTF_8))
            } catch (e: MalformedJsonException) {
                null
            }
            if (body is JsonObject) {
                val error = body["error"].stringOrNull()
                if (error != null) {
                    val message = body["message"].stringOrNull()
                    return if (message != null) "$error - $message" else error
                }
            }
            return response.reasonPhrase?.takeIf { it.isNotBlank() } ?: "HTTP ${response.statusCode}"
        }
    }
}
