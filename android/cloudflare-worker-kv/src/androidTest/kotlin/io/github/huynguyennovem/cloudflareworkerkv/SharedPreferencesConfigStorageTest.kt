package io.github.huynguyennovem.cloudflareworkerkv

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Runs [SharedPreferencesConfigStorage] against the real SharedPreferences of a device. */
@RunWith(AndroidJUnit4::class)
class SharedPreferencesConfigStorageTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val fileName = "cloudflare_worker_kv_test"

    @Before
    @After
    fun clearFile() {
        context.getSharedPreferences(fileName, Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test
    fun readWriteDelete() = runBlocking {
        val storage = SharedPreferencesConfigStorage(context, fileName)
        assertNull(storage.read("k"))
        storage.write("k", "v1")
        assertEquals("v1", storage.read("k"))
        storage.write("k", "v2")
        assertEquals("v2", storage.read("k"))
        storage.delete("k")
        assertNull(storage.read("k"))
    }

    @Test
    fun writesAreVisibleToNewInstances() = runBlocking {
        SharedPreferencesConfigStorage(context, fileName).write("k", "xin chào")
        assertEquals("xin chào", SharedPreferencesConfigStorage(context, fileName).read("k"))
        assertEquals(
            "xin chào",
            context.getSharedPreferences(fileName, Context.MODE_PRIVATE).getString("k", null),
        )
    }

    @Test
    fun defaultFileIsUsedByDefault() = runBlocking {
        val storage = SharedPreferencesConfigStorage(context)
        storage.write("probe", "1")
        val preferences = context.getSharedPreferences(
            SharedPreferencesConfigStorage.DEFAULT_FILE_NAME,
            Context.MODE_PRIVATE,
        )
        assertEquals("1", preferences.getString("probe", null))
        storage.delete("probe")
        assertNull(preferences.getString("probe", null))
    }
}
