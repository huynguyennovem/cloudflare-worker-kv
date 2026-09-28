package io.github.huynguyennovem.cloudflareworkerkv

import io.github.huynguyennovem.cloudflareworkerkv.helpers.FakeClock
import io.github.huynguyennovem.cloudflareworkerkv.helpers.FakeSharedPreferences
import io.github.huynguyennovem.cloudflareworkerkv.helpers.FakeWorker
import io.github.huynguyennovem.cloudflareworkerkv.helpers.RecordingLogger
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest

/** Port of flutter/test/storage_test.dart. */
class StorageTest {

    private suspend fun contract(storage: ConfigStorage) {
        assertNull(storage.read("k"))
        storage.write("k", "v1")
        assertEquals("v1", storage.read("k"))
        storage.write("k", "v2")
        assertEquals("v2", storage.read("k"))
        storage.delete("k")
        assertNull(storage.read("k"))
    }

    @Test
    fun `InMemoryConfigStorage - read write delete`() = runTest {
        contract(InMemoryConfigStorage())
    }

    @Test
    fun `InMemoryConfigStorage - initial data and a read-only copy`() = runTest {
        val storage = InMemoryConfigStorage(mapOf("a" to "1"))
        val snapshot = storage.data
        storage.write("b", "2")
        assertEquals(mapOf("a" to "1"), snapshot)
        assertEquals(mapOf("a" to "1", "b" to "2"), storage.data)
    }

    @Test
    fun `SharedPreferencesConfigStorage - read write delete`() = runTest {
        contract(SharedPreferencesConfigStorage(FakeSharedPreferences()))
    }

    @Test
    fun `SharedPreferencesConfigStorage - a failed commit throws`() = runTest {
        val preferences = FakeSharedPreferences()
        val storage = SharedPreferencesConfigStorage(preferences)
        storage.write("k", "v")
        preferences.commitResult = false
        assertFailsWith<IOException> { storage.write("k", "v2") }
        assertFailsWith<IOException> { storage.delete("k") }
        assertEquals("v", storage.read("k"))
    }

    @Test
    fun `default storage persists across instances`() = runTest {
        val worker = FakeWorker(mapOf("a" to "1"))
        val preferences = FakeSharedPreferences()
        val rc1 = create(worker, SharedPreferencesConfigStorage(preferences))
        rc1.setConfigSettings(RemoteConfigSettings(minimumFetchInterval = Duration.ZERO))
        rc1.fetchAndActivate()

        val rc2 = create(worker, SharedPreferencesConfigStorage(preferences))
        rc2.ensureInitialized()
        assertEquals("1", rc2.getString("a"))
        assertTrue(preferences.values.keys.single().startsWith("cloudflare_worker_kv:"))
        listOf(rc1, rc2).forEach { it.dispose() }
    }

    private fun TestScope.create(worker: FakeWorker, storage: ConfigStorage) = CloudflareRemoteConfig(
        endpoint = "https://cfg.example.com",
        template = CloudflareRemoteConfig.DEFAULT_TEMPLATE,
        clientKey = null,
        transport = worker,
        storage = storage,
        clock = FakeClock(),
        logger = RecordingLogger(),
        coroutineContext = StandardTestDispatcher(testScheduler),
    )
}
