package io.github.huynguyennovem.cloudflareworkerkv

/** Where a [RemoteConfigValue] came from. */
public enum class ValueSource {
    /** The key is unknown: there is neither an activated remote value nor a default. */
    STATIC,

    /** The value comes from the defaults passed to [CloudflareRemoteConfig.setDefaults]. */
    DEFAULT,

    /** The value comes from the activated remote config. */
    REMOTE,
}
