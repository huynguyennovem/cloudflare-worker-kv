package io.github.huynguyennovem.cloudflareworkerkv

import java.util.Collections
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Converts the values passed to [CloudflareRemoteConfig.setDefaults] to strings (spec §2.5). */
internal object DefaultsEncoder {

    /**
     * Strings are kept, numbers and booleans become their `toString()`, maps with string keys,
     * collections and arrays become compact JSON, and `null` values are skipped.
     *
     * @throws IllegalArgumentException for any other type.
     */
    fun encode(defaults: Map<String, Any?>): Map<String, String> {
        val encoded = LinkedHashMap<String, String>()
        for ((key, value) in defaults) {
            encoded[key] = when (value) {
                null -> continue
                is String -> value
                is Number, is Boolean -> value.toString()
                else -> toJson(value, key).toString()
            }
        }
        return Collections.unmodifiableMap(encoded)
    }

    private fun toJson(value: Any?, key: String): JsonElement = when (value) {
        null -> JsonNull
        is String -> JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        is Double -> finite(value.isFinite(), value, key)
        is Float -> finite(value.isFinite(), value, key)
        is Number -> JsonPrimitive(value)
        is Map<*, *> -> JsonObject(
            value.entries.associate { (k, v) ->
                require(k is String) { "Unsupported default for \"$key\": map keys must be strings." }
                k to toJson(v, key)
            },
        )
        is Collection<*> -> JsonArray(value.map { toJson(it, key) })
        is Array<*> -> JsonArray(value.map { toJson(it, key) })
        is IntArray -> JsonArray(value.map { JsonPrimitive(it) })
        is LongArray -> JsonArray(value.map { JsonPrimitive(it) })
        is ShortArray -> JsonArray(value.map { JsonPrimitive(it) })
        is ByteArray -> JsonArray(value.map { JsonPrimitive(it) })
        is DoubleArray -> JsonArray(value.map { toJson(it, key) })
        is FloatArray -> JsonArray(value.map { toJson(it, key) })
        is BooleanArray -> JsonArray(value.map { JsonPrimitive(it) })
        else -> throw IllegalArgumentException(
            "Unsupported default type ${value.javaClass.name} for \"$key\".",
        )
    }

    private fun finite(isFinite: Boolean, value: Number, key: String): JsonPrimitive {
        require(isFinite) { "Unsupported default for \"$key\": JSON has no NaN or infinite numbers." }
        return JsonPrimitive(value)
    }
}
