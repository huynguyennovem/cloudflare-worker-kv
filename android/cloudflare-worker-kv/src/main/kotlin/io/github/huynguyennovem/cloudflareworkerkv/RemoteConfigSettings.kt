package io.github.huynguyennovem.cloudflareworkerkv

import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.seconds

/**
 * Settings that control fetch behaviour. Create them with [remoteConfigSettings] or a
 * [Builder], and apply them with [CloudflareRemoteConfig.setConfigSettings].
 *
 * @property fetchTimeout maximum time for a whole fetch request, including reading the body.
 * @property minimumFetchInterval minimum age of the last successful fetch before
 *   [CloudflareRemoteConfig.fetch] hits the network again. Use [Duration.ZERO] during
 *   development.
 * @throws IllegalArgumentException if [fetchTimeout] is not positive, if
 *   [minimumFetchInterval] is negative, or if either is infinite.
 */
public class RemoteConfigSettings(
    public val fetchTimeout: Duration = DEFAULT_FETCH_TIMEOUT,
    public val minimumFetchInterval: Duration = DEFAULT_MINIMUM_FETCH_INTERVAL,
) {
    init {
        require(fetchTimeout.isPositive() && fetchTimeout.isFinite()) {
            "fetchTimeout must be greater than zero and finite, was $fetchTimeout."
        }
        require(!minimumFetchInterval.isNegative() && minimumFetchInterval.isFinite()) {
            "minimumFetchInterval must not be negative and must be finite, was $minimumFetchInterval."
        }
    }

    /** [fetchTimeout] in whole seconds. */
    public val fetchTimeoutInSeconds: Long get() = fetchTimeout.inWholeSeconds

    /** [minimumFetchInterval] in whole seconds. */
    public val minimumFetchIntervalInSeconds: Long get() = minimumFetchInterval.inWholeSeconds

    /** Returns a [Builder] initialised with these settings. */
    public fun toBuilder(): Builder = Builder().also {
        it.fetchTimeout = fetchTimeout
        it.minimumFetchInterval = minimumFetchInterval
    }

    override fun equals(other: Any?): Boolean =
        other is RemoteConfigSettings &&
            other.fetchTimeout == fetchTimeout &&
            other.minimumFetchInterval == minimumFetchInterval

    override fun hashCode(): Int = 31 * fetchTimeout.hashCode() + minimumFetchInterval.hashCode()

    override fun toString(): String =
        "RemoteConfigSettings(fetchTimeout=$fetchTimeout, minimumFetchInterval=$minimumFetchInterval)"

    /**
     * Builds [RemoteConfigSettings]. From Kotlin, prefer [remoteConfigSettings]; from Java, use
     * the `...InSeconds` setters.
     */
    public class Builder {
        /** See [RemoteConfigSettings.fetchTimeout]. Defaults to [DEFAULT_FETCH_TIMEOUT]. */
        public var fetchTimeout: Duration = DEFAULT_FETCH_TIMEOUT

        /**
         * See [RemoteConfigSettings.minimumFetchInterval]. Defaults to
         * [DEFAULT_MINIMUM_FETCH_INTERVAL].
         */
        public var minimumFetchInterval: Duration = DEFAULT_MINIMUM_FETCH_INTERVAL

        /** Sets [fetchTimeout] in seconds. */
        public fun setFetchTimeoutInSeconds(seconds: Long): Builder = apply {
            fetchTimeout = seconds.seconds
        }

        /** Sets [minimumFetchInterval] in seconds. */
        public fun setMinimumFetchIntervalInSeconds(seconds: Long): Builder = apply {
            minimumFetchInterval = seconds.seconds
        }

        /**
         * Creates the settings.
         *
         * @throws IllegalArgumentException if a value is out of range, see
         *   [RemoteConfigSettings].
         */
        public fun build(): RemoteConfigSettings = RemoteConfigSettings(fetchTimeout, minimumFetchInterval)
    }

    public companion object {
        /** The default [fetchTimeout]: 60 seconds. */
        public val DEFAULT_FETCH_TIMEOUT: Duration = 60.seconds

        /** The default [minimumFetchInterval]: 12 hours. */
        public val DEFAULT_MINIMUM_FETCH_INTERVAL: Duration = 12.hours
    }
}

/**
 * Creates [RemoteConfigSettings]:
 *
 * ```kotlin
 * remoteConfig.setConfigSettings(remoteConfigSettings {
 *     fetchTimeout = 10.seconds
 *     minimumFetchInterval = 1.hours
 * })
 * ```
 *
 * @throws IllegalArgumentException if a value is out of range, see [RemoteConfigSettings].
 */
public fun remoteConfigSettings(init: RemoteConfigSettings.Builder.() -> Unit): RemoteConfigSettings =
    RemoteConfigSettings.Builder().apply(init).build()
