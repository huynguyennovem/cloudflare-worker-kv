## 0.1.0

* Initial release of the `CloudflareWorkerKV` Swift package.
* `CloudflareRemoteConfig` API, close to Firebase Remote Config:
  `initialize(endpoint:)` / `shared`, `setConfigSettings`, `setDefaults`,
  `fetch`, `activate`, `fetchAndActivate`, `rc[key]` / `configValue(forKey:)`,
  `configValue(forKey:source:)`, `allKeys(from:)`, `allValues()`,
  `lastFetchStatus`, `lastFetchTime`.
* `RemoteConfigValue` with `stringValue`, `boolValue`, `intValue`,
  `doubleValue`, `numberValue`, `dataValue`, `jsonValue`, `decoded(asType:)`
  and `source`; `JSONValue` for structured defaults.
* `ETag` / `304 Not Modified`, `minimumFetchInterval`, 429 throttling with
  `Retry-After`, shared concurrent fetches and a `fetchTimeout` covering the
  whole request.
* Persistent cache in `UserDefaults`, in the format shared with the other SDKs
  of the repository; pluggable `ConfigStorage`; privacy manifest.
* iOS 15, macOS 12, tvOS 15, watchOS 8 and visionOS 1; Swift 6 language mode.
* Works with the companion Cloudflare Worker in the repository's `worker/`
  module, which serves config from Workers KV.
