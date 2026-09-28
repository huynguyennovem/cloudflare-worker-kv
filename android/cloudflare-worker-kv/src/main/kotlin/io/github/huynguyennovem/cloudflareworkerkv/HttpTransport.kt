package io.github.huynguyennovem.cloudflareworkerkv

/**
 * Sends the config request. The default is [HttpUrlConnectionTransport]; implement this
 * interface to use another HTTP client (OkHttp, Ktor, a proxy, a fake in tests, ...).
 *
 * Implementations must bypass any HTTP cache, and should stop the request when the calling
 * coroutine is cancelled: [CloudflareRemoteConfig] cancels it when
 * [RemoteConfigSettings.fetchTimeout] elapses.
 */
public interface HttpTransport {
    /**
     * Sends a GET request and returns the response, whatever its status code.
     *
     * @throws java.net.SocketTimeoutException if the request times out (reported as
     *   [RemoteConfigException.Code.TIMEOUT]).
     * @throws Exception on any other failure (reported as
     *   [RemoteConfigException.Code.NETWORK_ERROR]).
     */
    public suspend fun execute(request: HttpRequest): HttpResponse
}
