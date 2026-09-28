package io.github.huynguyennovem.cloudflareworkerkv

import android.content.Context
import android.content.SharedPreferences
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The default [ConfigStorage], backed by [SharedPreferences].
 *
 * Every call runs on [Dispatchers.IO], and writes use [SharedPreferences.Editor.commit], so a
 * completed [write] is on disk.
 */
public class SharedPreferencesConfigStorage private constructor(
    lazyPreferences: Lazy<SharedPreferences>,
) : ConfigStorage {

    /**
     * Stores the cache in the private preferences file [fileName] of the application.
     *
     * The file is opened lazily, on [Dispatchers.IO], on first use.
     */
    @JvmOverloads
    public constructor(context: Context, fileName: String = DEFAULT_FILE_NAME) : this(
        (context.applicationContext ?: context).let { app ->
            lazy { app.getSharedPreferences(fileName, Context.MODE_PRIVATE) }
        },
    )

    /** Stores the cache in [preferences]. */
    public constructor(preferences: SharedPreferences) : this(lazyOf(preferences))

    private val preferences: SharedPreferences by lazyPreferences

    override suspend fun read(key: String): String? = withContext(Dispatchers.IO) {
        preferences.getString(key, null)
    }

    /** @throws IOException if [SharedPreferences.Editor.commit] fails. */
    override suspend fun write(key: String, value: String): Unit = withContext(Dispatchers.IO) {
        if (!preferences.edit().putString(key, value).commit()) {
            throw IOException("Failed to commit the config cache to SharedPreferences.")
        }
    }

    /** @throws IOException if [SharedPreferences.Editor.commit] fails. */
    override suspend fun delete(key: String): Unit = withContext(Dispatchers.IO) {
        if (!preferences.edit().remove(key).commit()) {
            throw IOException("Failed to commit the config cache to SharedPreferences.")
        }
    }

    public companion object {
        /** The preferences file used by default: `cloudflare_worker_kv`. */
        public const val DEFAULT_FILE_NAME: String = "cloudflare_worker_kv"
    }
}
