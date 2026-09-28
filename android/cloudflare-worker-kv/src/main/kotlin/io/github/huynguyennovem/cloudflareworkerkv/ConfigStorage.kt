package io.github.huynguyennovem.cloudflareworkerkv

/**
 * Persistence for the cached config, so the last activated config survives app restarts.
 *
 * The default is [SharedPreferencesConfigStorage]. Implement this interface to use another
 * store. Implementations may throw: [CloudflareRemoteConfig] logs storage failures and keeps
 * working with the values it holds in memory.
 */
public interface ConfigStorage {
    /**
     * Returns the value stored under [key], or `null` if there is none.
     *
     * @throws Exception if the value cannot be read.
     */
    public suspend fun read(key: String): String?

    /**
     * Stores [value] under [key], replacing any previous value.
     *
     * @throws Exception if the value cannot be written.
     */
    public suspend fun write(key: String, value: String)

    /**
     * Removes [key].
     *
     * @throws Exception if the value cannot be removed.
     */
    public suspend fun delete(key: String)
}
