package io.github.huynguyennovem.cloudflareworkerkv

/**
 * Error thrown by [CloudflareRemoteConfig.fetch] and [CloudflareRemoteConfig.fetchAndActivate].
 *
 * A failed fetch never changes the active config: the getters keep returning cached or
 * default values.
 */
public class RemoteConfigException @JvmOverloads constructor(
    /** Machine-readable error code. */
    public val code: Code,
    /** Human-readable description. */
    override val message: String,
    /** HTTP status code, when the error came from an HTTP response. */
    public val statusCode: Int? = null,
    /** For [Code.THROTTLED]: when fetching may be retried, in milliseconds since the epoch. */
    public val throttleEndTimeMillis: Long? = null,
    cause: Throwable? = null,
) : Exception(message, cause) {

    /** Error codes. [value] is the same string in every SDK of this repository. */
    public enum class Code(
        /** The error code as a string, e.g. `network-error`. */
        public val value: String,
    ) {
        /** The request did not complete within [RemoteConfigSettings.fetchTimeout]. */
        TIMEOUT("timeout"),

        /** The request failed at the network layer. */
        NETWORK_ERROR("network-error"),

        /** The Worker rejected the client key (HTTP 401 or 403). */
        UNAUTHORIZED("unauthorized"),

        /** Fetching is rate limited (HTTP 429). See [throttleEndTimeMillis]. */
        THROTTLED("throttled"),

        /** The Worker responded with an unexpected HTTP status. */
        SERVER_ERROR("server-error"),

        /** The Worker responded with a body that is not a valid config payload. */
        INVALID_RESPONSE("invalid-response"),
    }

    /** For example `RemoteConfigException[server-error] (HTTP 502): boom`. */
    override fun toString(): String {
        val status = if (statusCode == null) "" else " (HTTP $statusCode)"
        return "RemoteConfigException[${code.value}]$status: $message"
    }
}
