/// Persistence used to cache fetched and activated config across app launches.
///
/// Implement this to plug in a different store (secure storage, Hive, ...).
/// Implementations may throw; failures are tolerated and never break reads.
abstract class ConfigStorage {
  /// Allows subclasses to have `const` constructors.
  const ConfigStorage();

  /// Returns the value stored under [key], or `null` if absent.
  Future<String?> read(String key);

  /// Stores [value] under [key], replacing any previous value.
  Future<void> write(String key, String value);

  /// Removes [key].
  Future<void> delete(String key);
}
