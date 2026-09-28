package io.github.huynguyennovem.cloudflareworkerkv.helpers

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/** Loads the shared fixtures from `spec/fixtures/` in the repository checkout. */
internal object SpecFixtures {
    fun load(name: String): JsonObject {
        val start = File(System.getProperty("user.dir") ?: ".").absoluteFile
        var dir: File? = start
        while (dir != null) {
            val file = File(dir, "spec/fixtures/$name")
            if (file.isFile) return Json.parseToJsonElement(file.readText()).jsonObject
            dir = dir.parentFile
        }
        error("spec/fixtures/$name not found in $start or any parent directory")
    }

    /** The `cases` array of the fixture [name]. */
    fun cases(name: String): List<JsonObject> {
        val cases = load(name)["cases"]?.jsonArray?.map { it.jsonObject }
        require(!cases.isNullOrEmpty()) { "$name has no cases" }
        return cases
    }
}
