import 'package:shared_preferences/shared_preferences.dart';

import 'config_storage.dart';

/// The default [ConfigStorage], backed by [SharedPreferencesAsync].
class SharedPreferencesConfigStorage implements ConfigStorage {
  /// Creates a storage using [preferences], or a new [SharedPreferencesAsync].
  SharedPreferencesConfigStorage({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> read(String key) => _preferences.getString(key);

  @override
  Future<void> write(String key, String value) =>
      _preferences.setString(key, value);

  @override
  Future<void> delete(String key) => _preferences.remove(key);
}
