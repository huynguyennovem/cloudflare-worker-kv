package io.github.huynguyennovem.cloudflareworkerkv

import kotlin.time.Duration.Companion.milliseconds
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Everything a [CloudflareRemoteConfig] persists. Replaced as a whole on every change. */
internal data class State(
    val active: ConfigSnapshot?,
    val fetched: ConfigSnapshot?,
    val etag: String?,
    val lastSuccessfulFetchMillis: Long?,
    val throttleEndMillis: Long?,
    val lastFetchStatus: FetchStatus,
    val settings: RemoteConfigSettings,
) {
    companion object {
        val INITIAL = State(
            active = null,
            fetched = null,
            etag = null,
            lastSuccessfulFetchMillis = null,
            throttleEndMillis = null,
            lastFetchStatus = FetchStatus.NO_FETCH_YET,
            settings = RemoteConfigSettings(),
        )
    }
}

/** The cache format shared with the other SDKs (spec §2.8). */
internal object PersistedState {
    const val FORMAT_VERSION = 1

    fun encode(state: State): String = buildJsonObject {
        put("formatVersion", FORMAT_VERSION)
        put("active", state.active?.toJson() ?: JsonNull)
        put("fetched", state.fetched?.toJson() ?: JsonNull)
        put("etag", state.etag)
        put("lastSuccessfulFetchMs", state.lastSuccessfulFetchMillis)
        put("throttleEndMs", state.throttleEndMillis)
        put("lastFetchStatus", state.lastFetchStatus.persistedName)
        put("settings", state.settings.toJson())
    }.toString()

    /**
     * Decodes a cache written by [encode] (or by another SDK).
     *
     * Invalid individual fields fall back to their defaults.
     *
     * @return the state, or `null` when [raw] is not an object with format version 1.
     * @throws MalformedJsonException when [raw] is not JSON or a snapshot is malformed.
     */
    fun decode(raw: String): State? {
        val json = parseStrictJson(raw)
        if (json !is JsonObject || json["formatVersion"].longOrNull() != FORMAT_VERSION.toLong()) return null
        return State(
            active = json["active"].snapshotOrNull(),
            fetched = json["fetched"].snapshotOrNull(),
            etag = json["etag"].stringOrNull(),
            lastSuccessfulFetchMillis = json["lastSuccessfulFetchMs"].longOrNull(),
            throttleEndMillis = json["throttleEndMs"].longOrNull(),
            lastFetchStatus = fetchStatusOf(json["lastFetchStatus"].stringOrNull()),
            settings = settingsFromJson(json["settings"]) ?: RemoteConfigSettings(),
        )
    }

    private fun JsonElement?.snapshotOrNull(): ConfigSnapshot? =
        if (this == null || this == JsonNull) null else ConfigSnapshot.fromJson(this)
}

/** The name the Dart reference implementation persists. */
internal val FetchStatus.persistedName: String
    get() = when (this) {
        FetchStatus.NO_FETCH_YET -> "noFetchYet"
        FetchStatus.SUCCESS -> "success"
        FetchStatus.FAILURE -> "failure"
        FetchStatus.THROTTLED -> "throttle"
    }

internal fun fetchStatusOf(persistedName: String?): FetchStatus =
    FetchStatus.entries.firstOrNull { it.persistedName == persistedName } ?: FetchStatus.NO_FETCH_YET

/** `{"fetchTimeoutMs": ..., "minimumFetchIntervalMs": ...}` */
internal fun RemoteConfigSettings.toJson(): JsonObject = buildJsonObject {
    put("fetchTimeoutMs", fetchTimeout.inWholeMilliseconds)
    put("minimumFetchIntervalMs", minimumFetchInterval.inWholeMilliseconds)
}

/** Restores settings saved by [toJson]; `null` on invalid input. */
internal fun settingsFromJson(json: JsonElement?): RemoteConfigSettings? {
    if (json !is JsonObject) return null
    val timeout = json["fetchTimeoutMs"].longOrNull() ?: return null
    val interval = json["minimumFetchIntervalMs"].longOrNull() ?: return null
    if (timeout <= 0 || interval < 0) return null
    return try {
        RemoteConfigSettings(timeout.milliseconds, interval.milliseconds)
    } catch (e: IllegalArgumentException) {
        null // Too large to be a finite Duration.
    }
}
