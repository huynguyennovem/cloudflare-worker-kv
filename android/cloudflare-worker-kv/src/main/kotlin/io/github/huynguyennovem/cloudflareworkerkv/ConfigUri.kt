package io.github.huynguyennovem.cloudflareworkerkv

import java.net.URI
import java.net.URISyntaxException

/** Builds the request URL from the configured endpoint (spec §2.1). */
internal object ConfigUri {
    private const val CONFIG_PATH = "/v1/config"

    /**
     * Appends `/v1/config` to the path of [endpoint] (removing one trailing `/`), keeps the
     * scheme, authority and query parameters, sets the `template` query parameter (in place
     * when it exists, otherwise last) and drops the fragment.
     *
     * @throws IllegalArgumentException if [endpoint] has no scheme or no host.
     */
    fun build(endpoint: String, template: String): String {
        val uri = try {
            URI(endpoint)
        } catch (e: URISyntaxException) {
            throw IllegalArgumentException("endpoint must be an absolute http(s) URL: $endpoint", e)
        }
        val scheme = uri.scheme
        val authority = uri.rawAuthority
        // URI.host is null for host names with an underscore, so check the raw authority.
        require(scheme != null && authority != null && hostOf(authority).isNotEmpty()) {
            "endpoint must be an absolute http(s) URL: $endpoint"
        }

        val path = (uri.rawPath ?: "").removeSuffix("/") + CONFIG_PATH

        // Like Dart's Uri.queryParameters: empty parts and parts without a name are skipped,
        // a repeated name keeps its first position and its last value.
        val parameters = LinkedHashMap<String, String>()
        uri.rawQuery?.split('&')?.forEach { part ->
            val separator = part.indexOf('=')
            when {
                separator < 0 -> if (part.isNotEmpty()) parameters[part] = ""
                separator > 0 -> parameters[part.substring(0, separator)] = part.substring(separator + 1)
            }
        }
        parameters["template"] = template
        val query = parameters.entries.joinToString("&") { (name, value) ->
            if (value.isEmpty()) name else "$name=$value"
        }
        return "$scheme://$authority$path?$query"
    }

    private fun hostOf(authority: String): String {
        val hostAndPort = authority.substringAfterLast('@')
        return if (hostAndPort.startsWith("[")) {
            hostAndPort.substringBefore(']').removePrefix("[")
        } else {
            hostAndPort.substringBefore(':')
        }
    }
}
