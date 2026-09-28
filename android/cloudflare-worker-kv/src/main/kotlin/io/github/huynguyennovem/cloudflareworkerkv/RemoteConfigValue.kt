package io.github.huynguyennovem.cloudflareworkerkv

/**
 * A config value with typed accessors.
 *
 * Values are stored as strings and converted on read. Conversions never throw: when a value
 * cannot be converted, the type's static default is returned instead. Values are trimmed
 * before they are parsed as a boolean or a number.
 *
 * @param value the raw value, or `null` for a static value (unknown key).
 * @property source where the value came from.
 */
public class RemoteConfigValue(
    private val value: String?,
    public val source: ValueSource,
) {
    /** The raw value, or [DEFAULT_VALUE_FOR_STRING] for a static value. */
    public fun asString(): String = value ?: DEFAULT_VALUE_FOR_STRING

    /**
     * `true` when the trimmed value is one of `1`, `true`, `t`, `yes`, `y`, `on`
     * (case-insensitive), `false` otherwise.
     */
    public fun asBoolean(): Boolean {
        val raw = value ?: return DEFAULT_VALUE_FOR_BOOLEAN
        return raw.trim().lowercase() in TRUE_VALUES
    }

    /**
     * The value parsed as a decimal integer with an optional sign, or [DEFAULT_VALUE_FOR_LONG]
     * when it is not one (`"10.0"` gives `0`) or does not fit in a [Long].
     */
    public fun asLong(): Long {
        val raw = value?.trim() ?: return DEFAULT_VALUE_FOR_LONG
        if (!INTEGER.matches(raw)) return DEFAULT_VALUE_FOR_LONG
        return raw.toLongOrNull() ?: DEFAULT_VALUE_FOR_LONG
    }

    /**
     * The value parsed as a decimal number with an optional fraction and exponent, or
     * [DEFAULT_VALUE_FOR_DOUBLE] when it is not one.
     */
    public fun asDouble(): Double {
        val raw = value?.trim() ?: return DEFAULT_VALUE_FOR_DOUBLE
        if (!DECIMAL.matches(raw)) return DEFAULT_VALUE_FOR_DOUBLE
        return raw.toDoubleOrNull() ?: DEFAULT_VALUE_FOR_DOUBLE
    }

    override fun equals(other: Any?): Boolean =
        other is RemoteConfigValue && other.value == value && other.source == source

    override fun hashCode(): Int = 31 * (value?.hashCode() ?: 0) + source.hashCode()

    override fun toString(): String = "RemoteConfigValue(value=$value, source=$source)"

    public companion object {
        /** Returned by [asString] for static values. */
        public const val DEFAULT_VALUE_FOR_STRING: String = ""

        /** Returned by [asLong] for static or non-integer values. */
        public const val DEFAULT_VALUE_FOR_LONG: Long = 0L

        /** Returned by [asDouble] for static or non-numeric values. */
        public const val DEFAULT_VALUE_FOR_DOUBLE: Double = 0.0

        /** Returned by [asBoolean] for static values. */
        public const val DEFAULT_VALUE_FOR_BOOLEAN: Boolean = false

        private val TRUE_VALUES = setOf("1", "true", "t", "yes", "y", "on")

        // ASCII only: keeps hexadecimal, NaN, type suffixes such as `1.5f` and non-ASCII
        // digits away from the platform parsers.
        private val INTEGER = Regex("[+-]?[0-9]+")
        private val DECIMAL = Regex("[+-]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][+-]?[0-9]+)?")
    }
}
