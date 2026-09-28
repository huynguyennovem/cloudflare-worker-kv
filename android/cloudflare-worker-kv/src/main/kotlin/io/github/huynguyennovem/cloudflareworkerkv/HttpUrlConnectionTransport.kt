package io.github.huynguyennovem.cloudflareworkerkv

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.TreeMap
import java.util.concurrent.Executor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * The default [HttpTransport], built on [HttpURLConnection], so it adds no dependency.
 *
 * It bypasses the HTTP cache, follows redirects and runs the blocking I/O on
 * [Dispatchers.IO]. Cancelling the calling coroutine disconnects the request.
 */
public class HttpUrlConnectionTransport internal constructor(
    private val executor: Executor,
) : HttpTransport {

    /** Creates a transport. */
    public constructor() : this(Dispatchers.IO.asExecutor())

    /**
     * Sends [request].
     *
     * @throws java.net.SocketTimeoutException if connecting or reading takes longer than
     *   [HttpRequest.timeout].
     * @throws IOException on any other network failure.
     */
    override suspend fun execute(request: HttpRequest): HttpResponse {
        val connection = URL(request.url).openConnection() as? HttpURLConnection
            ?: throw IOException("Unsupported URL scheme: ${request.url.substringBefore(':')}")
        val timeoutMillis = request.timeout.inWholeMilliseconds.coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()
        connection.requestMethod = "GET"
        connection.useCaches = false
        connection.instanceFollowRedirects = true
        connection.connectTimeout = timeoutMillis
        connection.readTimeout = timeoutMillis
        for ((name, value) in request.headers) connection.setRequestProperty(name, value)

        return suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation {
                // Unblocks a read in progress. Runs off the calling thread, which may be the
                // main thread.
                executor.execute { connection.disconnect() }
            }
            executor.execute {
                continuation.resumeWith(runCatching { read(connection) })
            }
        }
    }

    private fun read(connection: HttpURLConnection): HttpResponse {
        val statusCode = connection.responseCode
        if (statusCode < 0) throw IOException("Invalid HTTP response.")
        val stream = if (statusCode >= 400) connection.errorStream else connection.inputStream
        val body = stream?.use { it.readBytes() } ?: ByteArray(0)
        val headers = TreeMap<String, String>(String.CASE_INSENSITIVE_ORDER)
        for ((name, values) in connection.headerFields) {
            if (name == null) continue // The status line.
            headers[name] = values.joinToString(", ")
        }
        return HttpResponse(statusCode, headers, body, connection.responseMessage)
    }
}
