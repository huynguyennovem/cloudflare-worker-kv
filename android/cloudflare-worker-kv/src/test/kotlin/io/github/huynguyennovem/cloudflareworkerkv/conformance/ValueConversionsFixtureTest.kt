package io.github.huynguyennovem.cloudflareworkerkv.conformance

import io.github.huynguyennovem.cloudflareworkerkv.RemoteConfigValue
import io.github.huynguyennovem.cloudflareworkerkv.ValueSource
import io.github.huynguyennovem.cloudflareworkerkv.helpers.SpecFixtures
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.fail
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/** Runs every case of spec/fixtures/value-conversions.json (spec §2.4). */
@RunWith(Parameterized::class)
class ValueConversionsFixtureTest(
    @Suppress("unused") private val name: String,
    private val case: JsonObject,
) {
    @Test
    fun conversions() {
        if (case.keys != setOf("raw", "string", "bool", "int", "double")) fail("Unknown case shape: $case")
        val rawElement = case.getValue("raw")
        val raw = if (rawElement is JsonNull) null else rawElement.jsonPrimitive.content
        val value = RemoteConfigValue(raw, if (raw == null) ValueSource.STATIC else ValueSource.REMOTE)

        assertEquals(case.getValue("string").jsonPrimitive.content, value.asString(), "string")
        assertEquals(case.getValue("bool").jsonPrimitive.boolean, value.asBoolean(), "bool")
        assertEquals(case.getValue("int").jsonPrimitive.long, value.asLong(), "int")
        assertEquals(case.getValue("double").jsonPrimitive.double, value.asDouble(), "double")
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun cases(): List<Array<Any>> =
            SpecFixtures.cases("value-conversions.json").map { arrayOf(it.getValue("raw").toString(), it) }
    }
}
