/**
 * Where a {@link RemoteConfigValue} came from.
 *
 * - `static`: the key is unknown: neither a remote value nor a default exists.
 * - `default`: the value comes from `setDefaults`.
 * - `remote`: the value comes from the activated remote config.
 */
export type ValueSource = 'static' | 'default' | 'remote';

/** The {@link ValueSource} values. */
export const ValueSource: {
  readonly STATIC: 'static';
  readonly DEFAULT: 'default';
  readonly REMOTE: 'remote';
} = /* @__PURE__ */ Object.freeze({
  STATIC: 'static',
  DEFAULT: 'default',
  REMOTE: 'remote',
});

const TRUE_VALUES: ReadonlySet<string> = new Set(['1', 'true', 't', 'yes', 'y', 'on']);
const INTEGER_PATTERN = /^[+-]?\d+$/;

/**
 * A config value with typed accessors.
 *
 * All values are stored as strings and converted on read. Conversions never
 * throw: when a value cannot be converted, the type's static default is
 * returned instead.
 */
export class RemoteConfigValue {
  /** Returned by {@link asString} for static values. */
  static readonly DEFAULT_VALUE_FOR_STRING = '';
  /** Returned by {@link asNumber} and {@link asInteger} for static or unparsable values. */
  static readonly DEFAULT_VALUE_FOR_NUMBER = 0;
  /** Returned by {@link asBoolean} for static values. */
  static readonly DEFAULT_VALUE_FOR_BOOLEAN = false;

  private readonly value: string | undefined;
  private readonly source: ValueSource;

  /**
   * Creates a value from its raw string, which is `undefined` for static
   * (unknown key) values.
   */
  constructor(value: string | undefined, source: ValueSource) {
    this.value = value;
    this.source = source;
  }

  /** The raw value, or `''` for static values. */
  asString(): string {
    return this.value ?? RemoteConfigValue.DEFAULT_VALUE_FOR_STRING;
  }

  /**
   * The value parsed as a number (optional sign, fraction and exponent), or
   * `0` when it is not numeric. The value is trimmed first.
   */
  asNumber(): number {
    if (this.value === undefined) return RemoteConfigValue.DEFAULT_VALUE_FOR_NUMBER;
    const trimmed = this.value.trim();
    if (trimmed === '') return RemoteConfigValue.DEFAULT_VALUE_FOR_NUMBER;
    const parsed = Number(trimmed);
    return Number.isNaN(parsed) ? RemoteConfigValue.DEFAULT_VALUE_FOR_NUMBER : parsed;
  }

  /**
   * The value parsed as a decimal integer with an optional sign, or `0` when
   * it is not an integer (so `'10.0'` gives `0`). The value is trimmed first.
   */
  asInteger(): number {
    if (this.value === undefined) return RemoteConfigValue.DEFAULT_VALUE_FOR_NUMBER;
    const trimmed = this.value.trim();
    if (!INTEGER_PATTERN.test(trimmed)) return RemoteConfigValue.DEFAULT_VALUE_FOR_NUMBER;
    const parsed = Number(trimmed);
    // `+ 0` turns -0 into 0.
    return Number.isFinite(parsed) ? parsed + 0 : RemoteConfigValue.DEFAULT_VALUE_FOR_NUMBER;
  }

  /**
   * `true` when the trimmed, lower-cased value is one of
   * `1, true, t, yes, y, on`; `false` otherwise.
   */
  asBoolean(): boolean {
    if (this.value === undefined) return RemoteConfigValue.DEFAULT_VALUE_FOR_BOOLEAN;
    return TRUE_VALUES.has(this.value.trim().toLowerCase());
  }

  /** Where this value came from. */
  getSource(): ValueSource {
    return this.source;
  }
}
