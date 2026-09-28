package io.github.huynguyennovem.cloudflareworkerkv

import java.util.Collections
import java.util.TreeMap

/**
 * A response returned by an [HttpTransport].
 *
 * @property statusCode the HTTP status code.
 * @param headers the response headers; a header with several values has them joined with
 *   `", "`.
 * @property body the response body, for every status code.
 * @property reasonPhrase the reason phrase of the status line, if any.
 */
public class HttpResponse @JvmOverloads constructor(
    public val statusCode: Int,
    headers: Map<String, String>,
    public val body: ByteArray = ByteArray(0),
    public val reasonPhrase: String? = null,
) {
    /** The response headers, with case-insensitive names. */
    public val headers: Map<String, String> =
        Collections.unmodifiableMap(TreeMap<String, String>(String.CASE_INSENSITIVE_ORDER).apply { putAll(headers) })

    /** Returns the value of the header [name] (case-insensitive), or `null`. */
    public fun header(name: String): String? = headers[name]
}
