package io.github.huynguyennovem.cloudflareworkerkv

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/** Port of flutter/test/remote_config_value_test.dart, plus Kotlin-specific cases. */
class RemoteConfigValueTest {
    private fun remote(value: String) = RemoteConfigValue(value, ValueSource.REMOTE)

    @Test
    fun `asBoolean - truthy strings (case-insensitive, trimmed)`() {
        for (v in listOf("1", "true", "TRUE", "t", "T", "yes", "Y", "on", " On ")) {
            assertTrue(remote(v).asBoolean(), v)
        }
    }

    @Test
    fun `asBoolean - everything else is false`() {
        for (v in listOf("0", "false", "no", "off", "", "2", "truthy", "null")) {
            assertFalse(remote(v).asBoolean(), v)
        }
    }

    @Test
    fun `asLong - parses integers`() {
        assertEquals(42L, remote("42").asLong())
        assertEquals(-7L, remote("-7").asLong())
        assertEquals(5L, remote(" 5 ").asLong())
    }

    @Test
    fun `asLong - non-integers fall back to 0`() {
        for (v in listOf("1.5", "abc", "", "true", "10.0")) {
            assertEquals(0L, remote(v).asLong(), v)
        }
    }

    @Test
    fun `asDouble - parses numbers`() {
        assertEquals(1.5, remote("1.5").asDouble())
        assertEquals(3.0, remote("3").asDouble())
        assertEquals(-0.25, remote("-0.25").asDouble())
    }

    @Test
    fun `asDouble - non-numeric falls back to 0`() {
        for (v in listOf("abc", "", "true")) {
            assertEquals(0.0, remote(v).asDouble(), v)
        }
    }

    @Test
    fun `static values use type defaults`() {
        val v = RemoteConfigValue(null, ValueSource.STATIC)
        assertEquals("", v.asString())
        assertEquals(0L, v.asLong())
        assertEquals(0.0, v.asDouble())
        assertFalse(v.asBoolean())
        assertEquals(ValueSource.STATIC, v.source)
        assertEquals(RemoteConfigValue.DEFAULT_VALUE_FOR_STRING, v.asString())
        assertEquals(RemoteConfigValue.DEFAULT_VALUE_FOR_LONG, v.asLong())
        assertEquals(RemoteConfigValue.DEFAULT_VALUE_FOR_DOUBLE, v.asDouble())
        assertEquals(RemoteConfigValue.DEFAULT_VALUE_FOR_BOOLEAN, v.asBoolean())
    }

    @Test
    fun `equality and hashCode`() {
        assertEquals(remote("a"), remote("a"))
        assertEquals(remote("a").hashCode(), remote("a").hashCode())
        assertNotEquals(remote("a"), RemoteConfigValue("a", ValueSource.DEFAULT))
        assertNotEquals(remote("a"), remote("b"))
        assertEquals(RemoteConfigValue(null, ValueSource.STATIC), RemoteConfigValue(null, ValueSource.STATIC))
    }

    @Test
    fun `toString shows the value and the source`() {
        assertEquals("RemoteConfigValue(value=a, source=REMOTE)", remote("a").toString())
    }

    // Not normative (spec §3), but pinned so that the platform parsers never leak through.

    @Test
    fun `non-normative - exotic numbers are rejected`() {
        assertEquals(0L, remote("0x1F").asLong())
        assertEquals(0L, remote("1_000").asLong())
        assertEquals(0L, remote("٤٢").asLong()) // Arabic-Indic digits.
        assertEquals(0L, remote("99999999999999999999").asLong()) // Beyond 64 bits.
        assertEquals(0.0, remote("1.5f").asDouble())
        assertEquals(0.0, remote("1.5d").asDouble())
        assertEquals(0.0, remote("NaN").asDouble())
        assertEquals(0.0, remote("Infinity").asDouble())
        assertEquals(0.0, remote("0x1p3").asDouble())
        assertEquals(0.0, remote("٤٢").asDouble())
    }

    @Test
    fun `non-normative - signs, exponents and bare dots`() {
        assertEquals(7L, remote("+7").asLong())
        assertEquals(Long.MIN_VALUE, remote("-9223372036854775808").asLong())
        assertEquals(1000.0, remote("1E3").asDouble())
        assertEquals(0.015, remote("1.5e-2").asDouble())
        assertEquals(1.0, remote("1.").asDouble())
        assertEquals(0.0, remote(".").asDouble())
        assertEquals(0.0, remote("e3").asDouble())
    }
}
