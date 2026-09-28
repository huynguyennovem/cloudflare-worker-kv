## 0.1.0

* Initial release.
* `CloudflareRemoteConfig` API, modelled on Firebase Remote Config for Android:
  `initialize` / `instance`, `setDefaults`, `setConfigSettings`
  (`remoteConfigSettings { }`), `fetch`, `activate`, `fetchAndActivate`,
  `getString` / `getBoolean` / `getLong` / `getDouble` / `getValue` / `get` /
  `getAll`, and `info` (`fetchTimeMillis`, `lastFetchStatus`,
  `configSettings`).
* `ETag` / `304 Not Modified` support, `minimumFetchInterval`, 429 throttling
  with `Retry-After`. Concurrent fetches share one request.
* Persistent cache in `SharedPreferences`, pluggable `ConfigStorage`.
* Pluggable `HttpTransport`; the default uses `HttpURLConnection`.
* Passes the shared fixtures in the repository's `spec/fixtures`.
* Works with the companion Cloudflare Worker in the repository's `worker/`
  module, which serves config from Workers KV.
