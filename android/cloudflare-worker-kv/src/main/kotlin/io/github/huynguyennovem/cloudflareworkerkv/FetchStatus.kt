package io.github.huynguyennovem.cloudflareworkerkv

/** Outcome of the most recent fetch attempt, reported by [RemoteConfigInfo.lastFetchStatus]. */
public enum class FetchStatus {
    /** No fetch has been attempted yet. */
    NO_FETCH_YET,

    /** The last fetch succeeded, including "not modified" responses and fetches skipped by
     * [RemoteConfigSettings.minimumFetchInterval]. */
    SUCCESS,

    /** The last fetch failed: network error, timeout, invalid response, ... */
    FAILURE,

    /** The last fetch was rejected because of rate limiting (HTTP 429). */
    THROTTLED,
}
