package io.github.huynguyennovem.cloudflareworkerkv

/**
 * A snapshot of the fetch state of a [CloudflareRemoteConfig], returned by
 * [CloudflareRemoteConfig.info].
 */
public class RemoteConfigInfo internal constructor(
    /**
     * When the last successful fetch completed, in milliseconds since the epoch, or `-1` if no
     * fetch has succeeded yet.
     */
    public val fetchTimeMillis: Long,
    /** Outcome of the most recent fetch attempt. */
    public val lastFetchStatus: FetchStatus,
    /** The current fetch settings. */
    public val configSettings: RemoteConfigSettings,
) {
    override fun toString(): String =
        "RemoteConfigInfo(fetchTimeMillis=$fetchTimeMillis, lastFetchStatus=$lastFetchStatus, " +
            "configSettings=$configSettings)"
}
