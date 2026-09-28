package io.github.huynguyennovem.cloudflareworkerkv

import kotlin.time.Duration

/**
 * A GET request sent through an [HttpTransport].
 *
 * @property url the absolute request URL.
 * @property headers the request headers to send, and no others.
 * @property timeout the time limit for the whole request, [RemoteConfigSettings.fetchTimeout].
 */
public class HttpRequest(
    public val url: String,
    public val headers: Map<String, String>,
    public val timeout: Duration,
)
