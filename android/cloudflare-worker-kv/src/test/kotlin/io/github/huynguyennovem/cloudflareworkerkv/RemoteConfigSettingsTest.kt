package io.github.huynguyennovem.cloudflareworkerkv

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Port of flutter/test/remote_config_settings_test.dart, plus the Kotlin builder and DSL. */
class RemoteConfigSettingsTest {

    @Test
    fun `defaults to a 60 s timeout and a 12 h interval`() {
        val s = RemoteConfigSettings()
        assertEquals(60.seconds, s.fetchTimeout)
        assertEquals(12.hours, s.minimumFetchInterval)
        assertEquals(RemoteConfigSettings.DEFAULT_FETCH_TIMEOUT, s.fetchTimeout)
        assertEquals(RemoteConfigSettings.DEFAULT_MINIMUM_FETCH_INTERVAL, s.minimumFetchInterval)
    }

    @Test
    fun `validates durations`() {
        assertFailsWith<IllegalArgumentException> { RemoteConfigSettings(fetchTimeout = Duration.ZERO) }
        assertFailsWith<IllegalArgumentException> { RemoteConfigSettings(fetchTimeout = (-1).seconds) }
        assertFailsWith<IllegalArgumentException> { RemoteConfigSettings(fetchTimeout = Duration.INFINITE) }
        assertFailsWith<IllegalArgumentException> { RemoteConfigSettings(minimumFetchInterval = (-1).seconds) }
        assertFailsWith<IllegalArgumentException> { RemoteConfigSettings(minimumFetchInterval = Duration.INFINITE) }
        assertEquals(Duration.ZERO, RemoteConfigSettings(minimumFetchInterval = Duration.ZERO).minimumFetchInterval)
    }

    @Test
    fun `json round trip`() {
        val s = RemoteConfigSettings(fetchTimeout = 5.seconds, minimumFetchInterval = 3.minutes)
        assertEquals(
            buildJsonObject {
                put("fetchTimeoutMs", 5_000)
                put("minimumFetchIntervalMs", 180_000)
            },
            s.toJson(),
        )
        assertEquals(s, settingsFromJson(s.toJson()))
    }

    @Test
    fun `tryFromJson rejects invalid input`() {
        val inputs = listOf(
            null,
            JsonNull,
            JsonPrimitive("x"),
            JsonObject(emptyMap()),
            buildJsonObject {
                put("fetchTimeoutMs", "1")
                put("minimumFetchIntervalMs", 1)
            },
            buildJsonObject {
                put("fetchTimeoutMs", 0)
                put("minimumFetchIntervalMs", 1)
            },
            buildJsonObject {
                put("fetchTimeoutMs", 1)
                put("minimumFetchIntervalMs", -1)
            },
            // Kotlin-specific: non-integers and values beyond a finite Duration.
            buildJsonObject {
                put("fetchTimeoutMs", 1.5)
                put("minimumFetchIntervalMs", 1)
            },
            buildJsonObject {
                put("fetchTimeoutMs", 1)
                put("minimumFetchIntervalMs", Long.MAX_VALUE)
            },
        )
        for (json in inputs) {
            assertNull(settingsFromJson(json), "$json")
        }
    }

    @Test
    fun `DSL builds settings`() {
        val s = remoteConfigSettings {
            fetchTimeout = 10.seconds
            minimumFetchInterval = Duration.ZERO
        }
        assertEquals(RemoteConfigSettings(10.seconds, Duration.ZERO), s)
        assertEquals(RemoteConfigSettings(), remoteConfigSettings { })
        assertFailsWith<IllegalArgumentException> { remoteConfigSettings { fetchTimeout = Duration.ZERO } }
    }

    @Test
    fun `builder uses seconds for Java`() {
        val s = RemoteConfigSettings.Builder()
            .setFetchTimeoutInSeconds(5)
            .setMinimumFetchIntervalInSeconds(3600)
            .build()
        assertEquals(5.seconds, s.fetchTimeout)
        assertEquals(1.hours, s.minimumFetchInterval)
        assertEquals(5L, s.fetchTimeoutInSeconds)
        assertEquals(3600L, s.minimumFetchIntervalInSeconds)
        assertFailsWith<IllegalArgumentException> {
            RemoteConfigSettings.Builder().setMinimumFetchIntervalInSeconds(-1).build()
        }
    }

    @Test
    fun `toBuilder copies the settings`() {
        val s = RemoteConfigSettings(5.seconds, 3.minutes)
        assertEquals(s, s.toBuilder().build())
        assertEquals(RemoteConfigSettings(5.seconds, Duration.ZERO), s.toBuilder().setMinimumFetchIntervalInSeconds(0).build())
    }

    @Test
    fun `equality, hashCode and toString`() {
        assertEquals(RemoteConfigSettings(5.seconds, 3.minutes), RemoteConfigSettings(5.seconds, 3.minutes))
        assertEquals(
            RemoteConfigSettings(5.seconds, 3.minutes).hashCode(),
            RemoteConfigSettings(5.seconds, 3.minutes).hashCode(),
        )
        assertNotEquals(RemoteConfigSettings(5.seconds, 3.minutes), RemoteConfigSettings(5.seconds, 4.minutes))
        assertEquals(
            "RemoteConfigSettings(fetchTimeout=5s, minimumFetchInterval=3m)",
            RemoteConfigSettings(5.seconds, 3.minutes).toString(),
        )
    }
}
