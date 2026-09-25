import 'config_storage.dart';

/// A [ConfigStorage] that keeps data in memory only. Useful for tests.
class InMemoryConfigStorage implements ConfigStorage {
  /// Creates an in-memory storage, optionally pre-populated with [initial].
  InMemoryConfigStorage([Map<String, String>? initial]) : _data = {...?initial};

  final Map<String, String> _data;

  /// A read-only view of the stored data.
  Map<String, String> get data => Map.unmodifiable(_data);

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}
