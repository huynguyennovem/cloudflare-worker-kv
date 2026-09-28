package io.github.huynguyennovem.cloudflareworkerkv

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/** An immutable set of remote entries plus the version the Worker assigned to them. */
internal data class ConfigSnapshot(
    /** Opaque version identifier. */
    val version: String,
    /** Parameter values, always strings. */
    val entries: Map<String, String>,
) {
    /** Serialises the snapshot for persistence: `{"version": ..., "entries": {...}}`. */
    fun toJson(): JsonObject = buildJsonObject {
        put("version", version)
        putJsonObject("entries") {
            for ((key, value) in entries) put(key, value)
        }
    }

    companion object {
        val EMPTY = ConfigSnapshot("", emptyMap())

        /**
         * Parses a payload of the form `{"version": "...", "entries": {...}}`.
         *
         * `version` falls back to [fallbackVersion], then to `""`, when it is not a string.
         * Entry values are normalised to strings: strings are kept, `null` values dropped,
         * other primitives keep their JSON text, and objects and arrays become compact JSON.
         *
         * @throws MalformedJsonException when the shape is wrong.
         */
        fun fromJson(json: JsonElement?, fallbackVersion: String? = null): ConfigSnapshot {
            if (json !is JsonObject) throw MalformedJsonException("the payload must be a JSON object.")
            val rawEntries = json["entries"] as? JsonObject
                ?: throw MalformedJsonException("\"entries\" must be a JSON object.")
            val entries = LinkedHashMap<String, String>()
            for ((key, value) in rawEntries) {
                entries[key] = when (value) {
                    JsonNull -> continue
                    is JsonPrimitive -> value.content
                    else -> value.toString()
                }
            }
            return ConfigSnapshot(json["version"].stringOrNull() ?: fallbackVersion ?: "", entries)
        }

        /**
         * Decodes a `200` response body (strict UTF-8, strict JSON) with [fromJson].
         *
         * @throws MalformedJsonException when the body is not a valid payload.
         */
        fun parse(body: ByteArray, fallbackVersion: String?): ConfigSnapshot {
            val text = try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(body))
                    .toString()
            } catch (e: CharacterCodingException) {
                throw MalformedJsonException("the body is not valid UTF-8.")
            }
            return fromJson(parseStrictJson(text), fallbackVersion)
        }
    }
}

/** Thrown when a payload or a cache is not the JSON it should be. */
internal class MalformedJsonException(message: String) : Exception(message)

private const val MAX_JSON_DEPTH = 512
private val JSON_NUMBER = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")
private val JSON_INTEGER = Regex("-?[0-9]+")

/**
 * Parses [text] as strict JSON (RFC 8259).
 *
 * `Json.parseToJsonElement` rejects unquoted keys and trailing commas but accepts any unquoted
 * token as a value (`{"a":abc}`), so values are checked too. Nesting is limited, which keeps
 * the recursive `toString` of the result safe.
 *
 * @throws MalformedJsonException when [text] is not valid JSON.
 */
internal fun parseStrictJson(text: String): JsonElement {
    val element = try {
        Json.parseToJsonElement(text)
    } catch (e: IllegalArgumentException) { // Includes SerializationException.
        throw MalformedJsonException("not valid JSON.")
    }
    val pending = ArrayDeque<Pair<JsonElement, Int>>()
    pending.addLast(element to 1)
    while (pending.isNotEmpty()) {
        val (current, depth) = pending.removeLast()
        if (depth > MAX_JSON_DEPTH) throw MalformedJsonException("JSON nested too deeply.")
        when (current) {
            is JsonObject -> current.values.forEach { pending.addLast(it to depth + 1) }
            is JsonArray -> current.forEach { pending.addLast(it to depth + 1) }
            JsonNull -> Unit
            is JsonPrimitive -> if (!current.isString) {
                val literal = current.content
                if (literal != "true" && literal != "false" && !JSON_NUMBER.matches(literal)) {
                    throw MalformedJsonException("not valid JSON.")
                }
            }
        }
    }
    return element
}

/** The content of a JSON string, or `null` for anything else. */
internal fun JsonElement?.stringOrNull(): String? =
    (this as? JsonPrimitive)?.takeIf { it.isString }?.content

/** The value of a JSON integer that fits in a [Long], or `null` for anything else. */
internal fun JsonElement?.longOrNull(): Long? =
    (this as? JsonPrimitive)?.takeIf { !it.isString && it !is JsonNull }?.content?.let {
        if (JSON_INTEGER.matches(it)) it.toLongOrNull() else null
    }
