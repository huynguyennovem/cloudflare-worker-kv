/// Where a [RemoteConfigValue] came from.
enum ValueSource {
  /// The key is unknown: neither a remote value nor a default exists.
  valueStatic,

  /// The value comes from the defaults passed to `setDefaults`.
  valueDefault,

  /// The value comes from the activated remote config.
  valueRemote,
}

/// A config value with typed accessors.
///
/// All values are stored as strings and converted on read. Conversions never
/// throw: when a value cannot be converted, the type's static default is
/// returned instead.
class RemoteConfigValue {
  /// Creates a value from its raw string, which is `null` for static
  /// (unknown key) values.
  const RemoteConfigValue(this._value, this.source);

  /// Returned by [asString] for static values.
  static const String defaultValueForString = '';

  /// Returned by [asInt] for static or non-integer values.
  static const int defaultValueForInt = 0;

  /// Returned by [asDouble] for static or non-numeric values.
  static const double defaultValueForDouble = 0.0;

  /// Returned by [asBool] for static values.
  static const bool defaultValueForBool = false;

  static const Set<String> _trueValues = {'1', 'true', 't', 'yes', 'y', 'on'};

  final String? _value;

  /// Indicates where this value came from.
  final ValueSource source;

  /// The raw value as a string.
  String asString() => _value ?? defaultValueForString;

  /// The value parsed as an [int], or [defaultValueForInt] if not an integer.
  int asInt() {
    final value = _value;
    if (value == null) return defaultValueForInt;
    return int.tryParse(value.trim()) ?? defaultValueForInt;
  }

  /// The value parsed as a [double], or [defaultValueForDouble] if not numeric.
  double asDouble() {
    final value = _value;
    if (value == null) return defaultValueForDouble;
    return double.tryParse(value.trim()) ?? defaultValueForDouble;
  }

  /// `true` when the value is one of `1, true, t, yes, y, on`
  /// (case-insensitive), `false` otherwise.
  bool asBool() {
    final value = _value;
    if (value == null) return defaultValueForBool;
    return _trueValues.contains(value.trim().toLowerCase());
  }

  @override
  bool operator ==(Object other) =>
      other is RemoteConfigValue &&
      other._value == _value &&
      other.source == source;

  @override
  int get hashCode => Object.hash(_value, source);

  @override
  String toString() => 'RemoteConfigValue($_value, $source)';
}
