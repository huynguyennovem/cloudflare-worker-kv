## 0.1.1

* Update repository and issue tracker URLs after the repository was
  renamed to `cloudflare-worker-kv`.

## 0.1.0

* Initial release.
* `CloudflareRemoteConfig` API:
  `setDefaults`, `setConfigSettings`, `fetch`, `activate`, `fetchAndActivate`,
  `getString` / `getBool` / `getInt` / `getDouble` / `getValue` / `getAll`,
  `lastFetchTime`, `lastFetchStatus`.
* `ETag` / `304 Not Modified` support, `minimumFetchInterval`, 429 throttling.
* Persistent cache via `shared_preferences`, pluggable `ConfigStorage`.
* Works with the companion Cloudflare Worker in the repository's `worker/`
  module, which serves config from Workers KV.
