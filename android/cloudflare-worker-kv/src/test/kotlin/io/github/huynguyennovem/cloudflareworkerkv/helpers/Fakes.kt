package io.github.huynguyennovem.cloudflareworkerkv.helpers

import android.content.SharedPreferences
import io.github.huynguyennovem.cloudflareworkerkv.Clock
import io.github.huynguyennovem.cloudflareworkerkv.ConfigStorage
import io.github.huynguyennovem.cloudflareworkerkv.InMemoryConfigStorage
import io.github.huynguyennovem.cloudflareworkerkv.Logger
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.delay

/** 2026-01-01T00:00:00Z */
internal const val START_MILLIS: Long = 1_767_225_600_000L

/** A controllable clock. */
internal class FakeClock(var now: Long = START_MILLIS) : Clock {
    override fun nowMillis(): Long = now

    fun advance(duration: Duration) {
        now += duration.inWholeMilliseconds
    }
}

/** Records warnings instead of sending them to Logcat. */
internal class RecordingLogger : Logger {
    val warnings: MutableList<Pair<String, Throwable?>> = CopyOnWriteArrayList()

    override fun warn(message: String, throwable: Throwable?) {
        warnings += message to throwable
    }
}

/** A storage whose every call fails. */
internal class ThrowingStorage : ConfigStorage {
    override suspend fun read(key: String): String? = throw IllegalStateException("read")

    override suspend fun write(key: String, value: String): Unit = throw IllegalStateException("write")

    override suspend fun delete(key: String): Unit = throw IllegalStateException("delete")
}

/**
 * Earlier writes take longer (on virtual time), so unserialised writes would finish out of
 * order and leave stale data behind.
 */
internal class SlowStorage(
    private val inner: InMemoryConfigStorage = InMemoryConfigStorage(),
) : ConfigStorage by inner {
    private var nextDelay = 0L

    val data: Map<String, String> get() = inner.data

    fun resetDelays() {
        nextDelay = 30
    }

    override suspend fun write(key: String, value: String) {
        val wait = nextDelay
        nextDelay = (nextDelay - 10).coerceIn(0, 30)
        delay(wait.milliseconds)
        inner.write(key, value)
    }
}

/** An in-memory [SharedPreferences] whose `commit()` returns [commitResult]. */
internal class FakeSharedPreferences(var commitResult: Boolean = true) : SharedPreferences {
    val values: MutableMap<String, Any?> = LinkedHashMap()

    override fun getAll(): MutableMap<String, *> = LinkedHashMap(values)

    override fun getString(key: String?, defValue: String?): String? = values[key] as String? ?: defValue

    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
        values[key] as MutableSet<String>? ?: defValues

    override fun getInt(key: String?, defValue: Int): Int = values[key] as Int? ?: defValue

    override fun getLong(key: String?, defValue: Long): Long = values[key] as Long? ?: defValue

    override fun getFloat(key: String?, defValue: Float): Float = values[key] as Float? ?: defValue

    override fun getBoolean(key: String?, defValue: Boolean): Boolean = values[key] as Boolean? ?: defValue

    override fun contains(key: String?): Boolean = values.containsKey(key)

    override fun edit(): SharedPreferences.Editor = Editor()

    override fun registerOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ): Unit = throw UnsupportedOperationException()

    override fun unregisterOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ): Unit = throw UnsupportedOperationException()

    private inner class Editor : SharedPreferences.Editor {
        private val changes = LinkedHashMap<String, Any?>()
        private val removals = LinkedHashSet<String>()
        private var clear = false

        override fun putString(key: String, value: String?) = apply { changes[key] = value }

        override fun putStringSet(key: String, values: MutableSet<String>?) = apply { changes[key] = values }

        override fun putInt(key: String, value: Int) = apply { changes[key] = value }

        override fun putLong(key: String, value: Long) = apply { changes[key] = value }

        override fun putFloat(key: String, value: Float) = apply { changes[key] = value }

        override fun putBoolean(key: String, value: Boolean) = apply { changes[key] = value }

        override fun remove(key: String) = apply { removals += key }

        override fun clear() = apply { clear = true }

        override fun commit(): Boolean {
            if (!commitResult) return false
            apply()
            return true
        }

        override fun apply() {
            if (clear) values.clear()
            removals.forEach { values.remove(it) }
            values.putAll(changes)
        }
    }
}
