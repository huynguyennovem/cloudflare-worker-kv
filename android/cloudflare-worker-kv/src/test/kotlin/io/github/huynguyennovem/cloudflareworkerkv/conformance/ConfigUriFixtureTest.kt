package io.github.huynguyennovem.cloudflareworkerkv.conformance

import io.github.huynguyennovem.cloudflareworkerkv.ConfigUri
import io.github.huynguyennovem.cloudflareworkerkv.helpers.SpecFixtures
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.fail
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/** Runs every case of spec/fixtures/config-uri.json (spec §2.1), compared as exact strings. */
@RunWith(Parameterized::class)
class ConfigUriFixtureTest(
    @Suppress("unused") private val name: String,
    private val case: JsonObject,
) {
    @Test
    fun buildsTheRequestUrl() {
        val endpoint = case.getValue("endpoint").jsonPrimitive.content
        val template = case.getValue("template").jsonPrimitive.content
        when (case.keys) {
            setOf("endpoint", "template", "expected") ->
                assertEquals(case.getValue("expected").jsonPrimitive.content, ConfigUri.build(endpoint, template))
            setOf("endpoint", "template", "error") -> {
                if (case["error"] != JsonPrimitive(true)) fail("Unknown case shape: $case")
                assertFailsWith<IllegalArgumentException> { ConfigUri.build(endpoint, template) }
            }
            else -> fail("Unknown case shape: $case")
        }
    }

    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun cases(): List<Array<Any>> = SpecFixtures.cases("config-uri.json").map {
            arrayOf("${it.getValue("endpoint").jsonPrimitive.content} + ${it.getValue("template").jsonPrimitive.content}", it)
        }
    }
}
