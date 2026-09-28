package io.github.huynguyennovem.cloudflareworkerkv

import java.util.Collections

/**
 * A [ConfigStorage] that keeps data in memory only. Useful for tests, or to disable the
 * offline cache.
 *
 * @param initial values to start with.
 */
public class InMemoryConfigStorage @JvmOverloads constructor(
    initial: Map<String, String> = emptyMap(),
) : ConfigStorage {
    private val lock = Any()
    private val values = LinkedHashMap(initial)

    /** A read-only copy of the stored data. */
    public val data: Map<String, String>
        get() = synchronized(lock) { Collections.unmodifiableMap(LinkedHashMap(values)) }

    override suspend fun read(key: String): String? = synchronized(lock) { values[key] }

    override suspend fun write(key: String, value: String) {
        synchronized(lock) { values[key] = value }
    }

    override suspend fun delete(key: String) {
        synchronized(lock) { values.remove(key) }
    }
}
