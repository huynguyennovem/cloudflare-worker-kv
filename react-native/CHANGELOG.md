# Changelog

## 0.1.0

* Initial release.
* `CloudflareRemoteConfig` API, modelled on
  `@react-native-firebase/remote-config`:
  `initialize` / `instance`, `setDefaults`, `setConfigSettings`, `fetch`,
  `activate`, `fetchAndActivate`, `getString` / `getNumber` / `getBoolean` /
  `getValue` / `getAll`, `fetchTimeMillis`, `lastFetchStatus`, `settings`.
* `RemoteConfigValue` with `asString` / `asNumber` / `asInteger` /
  `asBoolean` / `getSource`.
* `ETag` / `304 Not Modified` support, `minimumFetchIntervalMillis`,
  429 throttling, a fetch timeout that covers reading the body.
* Persistent cache via AsyncStorage (v1, v2 or v3), pluggable
  `ConfigStorage`; `InMemoryConfigStorage` for tests.
* Pure TypeScript, ES modules only; works in Expo Go and on the web.
* Works with the companion Cloudflare Worker in the repository's `worker/`
  module, which serves config from Workers KV.
