# CloudflareWorkerKV

Remote config for iOS, macOS, tvOS, watchOS and visionOS, backed by
**Cloudflare Workers KV**. A Swift package with no dependencies.

- In-app defaults, `fetch()` / `activate()` / `fetchAndActivate()`
- Typed values: `rc["key"].stringValue`, `.boolValue`, `.intValue`,
  `.doubleValue`, `.jsonValue`, `.decoded(asType:)`, and the `source` of each value
- `RemoteConfigSettings` with `fetchTimeout` and `minimumFetchInterval`
- Offline cache: the last activated config is restored on the next launch
- Bandwidth-friendly: `ETag` / `304 Not Modified`
- Swift 6 and strict concurrency; synchronous, thread-safe getters that work in a SwiftUI `body`
- An API close to Firebase Remote Config for Apple platforms

## How it works

The package talks to a small read-only Cloudflare Worker, so your app never
holds a Cloudflare API token. The Worker, and how to deploy it against your KV
namespace, lives in the [`worker/` module](../worker/) of this repository.
Any backend that implements the [HTTP contract](../spec/README.md) works too.

The package behaves exactly like the other SDKs of this repository (Flutter,
React Native, Android): the [contract](../spec/README.md) describes that
behaviour, and all SDKs run the same test fixtures.

## Installation

You need the URL of a deployed Worker, for example
`https://my-config.<subdomain>.workers.dev`.

In Xcode: **File › Add Package Dependencies…**, enter
`https://github.com/huynguyennovem/cloudflare-worker-kv` and add the
`CloudflareWorkerKV` library to your app target.

In a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/huynguyennovem/cloudflare-worker-kv", .upToNextMinor(from: "0.1.0")),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "CloudflareWorkerKV", package: "cloudflare-worker-kv"),
    ]),
]
```

The package identity is `cloudflare-worker-kv`, and the product and module are
`CloudflareWorkerKV`. Until 1.0, minor versions may contain breaking changes,
hence `.upToNextMinor`.

Requirements: Swift 6 (Xcode 16 or later), iOS 15, macOS 12, tvOS 15, watchOS 8
or visionOS 1.

## Usage

```swift
import CloudflareWorkerKV

// Once, early in the app's life (for example in a `.task` of the root view):
let remoteConfig = await CloudflareRemoteConfig.initialize(
    endpoint: URL(string: "https://my-config.example.workers.dev")!,
    clientKey: "optional-client-key" // only if the Worker sets CLIENT_KEY
)
await remoteConfig.setConfigSettings(RemoteConfigSettings(
    fetchTimeout: 10,
    minimumFetchInterval: 3_600 // seconds; use 0 during development
))
remoteConfig.setDefaults([
    "welcome_message": "Hello",
    "max_items": 10,
    "new_checkout_enabled": false,
])

do {
    try await remoteConfig.fetchAndActivate()
} catch {
    // Offline, timeout, ... cached and default values are still available.
    print("Remote config fetch failed: \(error)")
}

// Anywhere in the app:
let rc = CloudflareRemoteConfig.shared
let maxItems = rc["max_items"].intValue
let newCheckout = rc["new_checkout_enabled"].boolValue
```

`initialize` loads the cached config before it returns, so values are
available right away, even offline.

Values are delivered as strings and converted by the typed accessors. A
parameter stored as a JSON object or array arrives as JSON text:

```swift
struct AdUnits: Decodable { let banner: String }

let units = try rc["ad_units"].decoded(asType: AdUnits.self)
let raw = rc["ad_units"].jsonValue // JSONValue?, nil when not JSON
```

Structured defaults use `JSONValue`, which is expressible by literals:

```swift
remoteConfig.setDefaults(["ad_units": ["banner": "ca-app-pub-1", "sizes": [320, 728]] as JSONValue])
```

The getters are not observable. In SwiftUI, refresh your view state after
`fetchAndActivate()` (or `activate()`) returns; see the example app.

Errors are `RemoteConfigError` values:

```swift
do {
    try await remoteConfig.fetch()
} catch let error as RemoteConfigError where error.code == .throttled {
    print("Rate limited until \(error.throttleEndTime!)")
} catch {
    print(error) // RemoteConfigError[network-error]: ...
}
```

Pass your own `URLSession` with `session:` (proxies, protocol classes,
certificate pinning) and your own `ConfigStorage` with `storage:`.

### Example app

[`Example/`](Example/) is a SwiftUI app (iOS 17) showing the values, their
sources and the fetch status, with a *Fetch & activate* button. Give it your
Worker URL, either by copying `Example/Config/Local.xcconfig.example` to
`Example/Config/Local.xcconfig` (ignored by Git) and editing it, or on the
command line:

```bash
xcodebuild build \
  -project ios/Example/CloudflareWorkerKVExample.xcodeproj \
  -scheme CloudflareWorkerKVExample \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath ios/Example/build \
  CF_CONFIG_ENDPOINT='https://my-config.example.workers.dev'
```

In an `.xcconfig` file, `//` starts a comment even inside a value: write
`https:/$()/my-config.example.workers.dev`. The app allows plain HTTP to
`localhost`, so `http://localhost:8787` from `npx wrangler dev` works in the
Simulator.

### Migrating from Firebase Remote Config

| FirebaseRemoteConfig | CloudflareWorkerKV |
| --- | --- |
| `RemoteConfig.remoteConfig()` | `await CloudflareRemoteConfig.initialize(endpoint:)` once, then `CloudflareRemoteConfig.shared` |
| `configSettings = settings` / `minimumFetchInterval` | `await setConfigSettings(RemoteConfigSettings(fetchTimeout:minimumFetchInterval:))`, persisted |
| `setDefaults(["k": 5 as NSObject])` | `setDefaults(["k": 5])`: no `as NSObject`, unsupported types do not compile |
| `setDefaults(fromPlist:)` | not supported |
| `fetch()`, `activate()` | same, `async` |
| `fetch(withExpirationDuration:)` | `fetch()`, which honours `minimumFetchInterval` |
| `fetchAndActivate()` → `RemoteConfigFetchAndActivateStatus` | `fetchAndActivate()` → `Bool` (`true` when a new config was activated) |
| `rc["k"]`, `configValue(forKey:)`, `configValue(forKey:source:)` | same |
| `stringValue`, `boolValue`, `numberValue`, `dataValue`, `jsonValue`, `decoded(asType:)` | same, plus `intValue` and `doubleValue`; `jsonValue` is a `JSONValue?` |
| `allKeys(from:)` | same (sorted), plus `allValues()` |
| `lastFetchStatus`, `lastFetchTime` | same; `lastFetchTime` is `nil` before the first successful fetch |
| `RemoteConfigSource`, `RemoteConfigFetchStatus` | same cases |
| `NSError` in `RemoteConfigErrorDomain` | `RemoteConfigError` (`code`, `message`, `statusCode`, `throttleEndTime`) |
| `addOnConfigUpdateListener` | not supported |
| Conditions, personalization, A/B testing | not supported |

While both SDKs are linked, `RemoteConfigSettings`, `RemoteConfigValue`,
`RemoteConfigSource`, `RemoteConfigFetchStatus` and `RemoteConfigError`
exist in both modules: qualify them, as in
`CloudflareWorkerKV.RemoteConfigSettings`.

## Behaviour

- **Value resolution:** activated remote value → default → static
  (`""`, `0`, `0.0`, `false`). `rc[key].source` tells you which
  (`.remote`, `.default`, `.static`).
- **Conversions:** `boolValue` is `true` for `1, true, t, yes, y, on`
  (case-insensitive, trimmed). `intValue` accepts a decimal integer with an
  optional sign (`"10.0"` gives `0`); `doubleValue` accepts a decimal number
  with an optional fraction and exponent. Conversions never fail: they return
  `0` / `0.0` instead.
- **`fetch()`** never changes what the getters return; call `activate()`.
  Within `minimumFetchInterval` of the last successful fetch it completes
  without a network request. Concurrent calls share one request, and
  cancelling a caller's task does not cancel it: `fetchTimeout` bounds it.
- **`activate()`** returns `true` only when a fetched config differs from the
  active one.
- **Errors:** `fetch()` only throws `RemoteConfigError`, with a `code` of
  `.timeout`, `.networkError`, `.unauthorized`, `.throttled`, `.serverError`
  or `.invalidResponse` (raw values `timeout`, `network-error`, ... are the
  same in every SDK). A failed fetch never touches the active config. HTTP 429
  sets `lastFetchStatus` to `.throttled` and blocks fetches until
  `throttleEndTime` (from `Retry-After`, default 1 minute).
- **Timeouts:** `fetchTimeout` limits the whole request, body included
  (`URLRequest.timeoutInterval` alone is an idle timeout).
- **HTTP cache:** the SDK bypasses `URLCache`, so a `304` is never turned into
  a cached `200`. By default it uses its own ephemeral `URLSession`.
- **Freshness:** a change made in KV reaches the Worker after about 1–2
  minutes. The app picks it up on its next fetch, which `minimumFetchInterval`
  may delay.
- **Persistence:** active and pending config, `ETag`, settings and fetch
  status are stored in `UserDefaults.standard`, under
  `cloudflare_worker_kv:<endpoint>|<template>`, in the same format as the
  other SDKs. Pass `UserDefaultsConfigStorage(userDefaults:)` (an app group
  suite, for example) or your own `ConfigStorage` to change that. Storage
  errors are logged, never thrown. Defaults are not persisted: set them on
  every launch.
- **Multiple configs:** create extra instances with
  `CloudflareRemoteConfig(endpoint: ..., template: "staging")` and call
  `await ensureInitialized()` before reading them; each endpoint/template
  pair has its own cache.
- **Programming errors:** an endpoint without a scheme and a host, a template
  that does not match `[A-Za-z0-9_-]{1,64}`, invalid settings, or
  `shared` before `initialize` stop the app with a precondition failure.
- **Thread safety:** every method can be called from any thread or actor.

## Security

- The Worker only exposes **read** access to your config.
  Do not put secrets in remote config: anyone with the app can read it.
- `clientKey` is a shared value compiled into the app. It keeps casual
  traffic away from your Worker but is **not** a secret. Combine with
  [Cloudflare rate limiting](https://developers.cloudflare.com/waf/rate-limiting-rules/)
  if you need abuse protection. The SDK never logs it.
- Logs go to the unified log, subsystem
  `io.github.huynguyennovem.CloudflareWorkerKV`.

## Platform notes

- **macOS:** sandboxed apps need the `com.apple.security.network.client`
  entitlement (*Outgoing Connections (Client)*).
- **App Transport Security:** use an `https` endpoint. For a local
  `wrangler dev` Worker, set `NSAllowsLocalNetworking` in your app's
  `NSAppTransportSecurity`, like the example app does.
- **Privacy manifest:** the package ships a `PrivacyInfo.xcprivacy` declaring
  its `UserDefaults` use (reason `CA92.1`). It does no tracking and collects
  no data.
- **tvOS:** `UserDefaults` is small on tvOS. For large configs, provide a
  `ConfigStorage` that writes a file, for example in the caches directory.
- **watchOS:** `Int` is 32 bits on Apple Watch (arm64_32), so `intValue`
  returns `0` above `Int32.max`; parse `stringValue` with `Int64` if you need
  larger numbers.

## HTTP contract

```
GET {endpoint}/v1/config?template={template}
  Request headers:  Accept, X-Client-Key (optional), If-None-Match (optional)
  200  {"version": "<opaque>", "entries": {"key": "value", ...}}   + ETag header
  304  when If-None-Match matches
  401/403 bad client key · 429 rate limited (Retry-After) · 5xx errors
```

The full contract, including how clients must behave, is in
[`spec/README.md`](../spec/README.md).

## Running the tests

From the repository root, where `Package.swift` lives:

```bash
swift test
xcodebuild test -scheme CloudflareWorkerKV -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The tests use Swift Testing and need no network. They read the shared
fixtures from `spec/fixtures/` of the checkout, found from the test sources'
`#filePath`, so run them from a clone of the repository. The precondition
tests are exit tests, which only run on macOS with Swift 6.2 or later.
