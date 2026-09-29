# cloudflare-worker-kv for Android

Remote config for Android, backed by **Cloudflare Workers KV**. Written in
Kotlin, with an API modelled on Firebase Remote Config.

- In-app defaults, `fetch` / `activate` / `fetchAndActivate` as suspend functions
- Typed getters: `getString`, `getBoolean`, `getLong`, `getDouble`, `getValue`, `getAll`, `remoteConfig["key"]`
- `remoteConfigSettings { fetchTimeout; minimumFetchInterval }` with `kotlin.time.Duration`
- Offline cache: the last activated config is restored on the next launch
- Bandwidth-friendly: `ETag` / `304 Not Modified`
- Small: depends only on kotlinx-coroutines and kotlinx-serialization-json, uses
  `HttpURLConnection` and `SharedPreferences`, needs no ProGuard rules

## How it works

![Your app sends GET /v1/config?template=default to the Cloudflare Worker, which reads Workers KV and replies 200 {version, entries} or 304](../assets/how-it-works.svg)

The library talks to a small read-only Cloudflare Worker, so your app never
holds a Cloudflare API token. The Worker, and how to deploy it against your KV
namespace, lives in the [`worker/` module](../worker/) of this repository. Any
backend that implements the [HTTP contract](../spec/README.md) works too.

The library behaves exactly like the Flutter, React Native and iOS SDKs of this
repository: they all follow [`spec/README.md`](../spec/README.md) and run its
shared test fixtures.

## Installation

You need the URL of a deployed Worker, e.g.
`https://my-config.<subdomain>.workers.dev`.

The library is published to
[Maven Central](https://central.sonatype.com/artifact/io.github.huynguyennovem/cloudflare-worker-kv):

```kotlin
// build.gradle.kts
dependencies {
    implementation("io.github.huynguyennovem:cloudflare-worker-kv:0.1.0")
}
```

- `minSdk` 23. Kotlin 2.1 or newer.
- The `INTERNET` permission is declared by the library and merged into your
  manifest automatically.

## Usage

Initialize once, from a coroutine, for example in your `Application`:

```kotlin
class MyApp : Application() {
    private val appScope = MainScope()

    override fun onCreate() {
        super.onCreate()
        appScope.launch {
            val remoteConfig = CloudflareRemoteConfig.initialize(
                this@MyApp,
                endpoint = "https://my-config.<subdomain>.workers.dev",
                clientKey = "optional-client-key", // only if the Worker sets CLIENT_KEY
            )
            remoteConfig.setConfigSettings(
                remoteConfigSettings {
                    fetchTimeout = 10.seconds
                    minimumFetchInterval = 1.hours
                },
            )
            remoteConfig.setDefaults(
                mapOf(
                    "welcome_message" to "Hello",
                    "max_items" to 10,
                    "new_checkout_enabled" to false,
                ),
            )
            try {
                remoteConfig.fetchAndActivate()
            } catch (e: RemoteConfigException) {
                // Offline, timeout, ... cached or default values are still available.
                Log.w("MyApp", "Remote config fetch failed: ${e.code.value}", e)
            }
        }
    }
}
```

Then, anywhere in the app once `initialize` has returned:

```kotlin
val rc = CloudflareRemoteConfig.instance
val maxItems = rc.getLong("max_items")
val newCheckout = rc.getBoolean("new_checkout_enabled")
val welcome = rc["welcome_message"].asString()
```

`instance` throws `IllegalStateException` until `initialize` has returned. If
your UI can start first, share the initialization instead, for example as a
`Deferred<CloudflareRemoteConfig>` like the [example app](example/) does.

The getters never block: they read what is in memory. They are safe to call
from the main thread and from Compose.

Values are delivered as strings and converted by the typed getters. A
parameter stored as a JSON object or array arrives as JSON text:

```kotlin
val units = JSONObject(rc.getString("ad_units")) // org.json, built into Android
```

See [`example/`](example/) for a complete Jetpack Compose app.

### Migrating from Firebase Remote Config

| Firebase Remote Config (Android)                          | cloudflare-worker-kv                                               |
| --------------------------------------------------------- | ------------------------------------------------------------------ |
| `Firebase.remoteConfig`                                   | `CloudflareRemoteConfig.instance` (after `initialize(context, endpoint)`) |
| `setConfigSettingsAsync(remoteConfigSettings { minimumFetchIntervalInSeconds = 3600 })` | `setConfigSettings(remoteConfigSettings { minimumFetchInterval = 1.hours })` |
| `setDefaultsAsync(map)`                                   | `setDefaults(map)` (maps only, no XML resource)                     |
| `ensureInitialized()`                                     | same (done by `initialize`)                                        |
| `fetch()` / `activate()` / `fetchAndActivate()` (`Task`)  | same, as suspend functions                                         |
| `getString` / `getBoolean` / `getLong` / `getDouble` / `getValue` / `getAll`, `remoteConfig["key"]` | same |
| `FirebaseRemoteConfigValue` `asString()` … `source`       | `RemoteConfigValue`, `source` is a `ValueSource` enum; conversions never throw |
| `info.fetchTimeMillis`, `info.lastFetchStatus`, `info.configSettings` | same; `lastFetchStatus` is a `FetchStatus` enum          |
| `FirebaseRemoteConfigException`                           | `RemoteConfigException` (`code`, `statusCode`)                     |
| `addOnConfigUpdateListener`                               | not yet                                                            |
| Conditions, A/B testing, personalization                  | not supported                                                      |

## Behaviour

- **Value resolution:** activated remote value → default → static
  (`""`, `0`, `0.0`, `false`). `getValue(key).source` tells you which
  (`REMOTE`, `DEFAULT` or `STATIC`).
- **Conversions:** `asBoolean()` is `true` for `1, true, t, yes, y, on`
  (case-insensitive). `asLong()` / `asDouble()` return `0` / `0.0` when the
  value is not a plain decimal number (`"10.0"` is not a `Long`). Conversions
  never throw.
- **`fetch()`** never changes what the getters return; call `activate()`.
  Within `minimumFetchInterval` of the last successful fetch it returns
  without a network request. Concurrent calls share one request, and
  cancelling one caller does not cancel it for the others.
- **`activate()`** returns `true` only when a fetched config differs from the
  active one.
- **Errors:** `fetch()` throws `RemoteConfigException` with a `code` of
  `TIMEOUT`, `NETWORK_ERROR`, `UNAUTHORIZED`, `THROTTLED`, `SERVER_ERROR` or
  `INVALID_RESPONSE` (`code.value` is `timeout`, `network-error`, …). A failed
  fetch never touches the active config. HTTP 429 sets
  `info.lastFetchStatus` to `THROTTLED` and blocks fetches until
  `throttleEndTimeMillis` (from `Retry-After`, default 1 minute). Cancelling
  the calling coroutine throws `CancellationException`, as usual.
- **Timeout:** `fetchTimeout` limits the whole request, including reading the
  body.
- **Freshness:** a change made in KV reaches the Worker after about 1–2
  minutes. The app picks it up on its next fetch, which `minimumFetchInterval`
  may delay.
- **Persistence:** active and pending config, `ETag`, settings and fetch
  status are stored in the `SharedPreferences` file `cloudflare_worker_kv`
  (written with `commit()` on `Dispatchers.IO`). Pass your own `ConfigStorage`
  to change that, or `InMemoryConfigStorage()` to disable it. Storage errors
  are logged, never thrown. Defaults are not persisted — set them on every
  launch.
- **Multiple configs:** create extra instances with
  `CloudflareRemoteConfig(context, endpoint, template = "staging")` and call
  `ensureInitialized()`; each endpoint/template pair has its own cache.
  Calling `initialize` again replaces the shared instance and disposes the old
  one.
- **Custom HTTP client:** pass your own `HttpTransport` (OkHttp, Ktor, …). It
  must bypass the HTTP cache and stop the request when its coroutine is
  cancelled.

## Security

- The Worker only exposes **read** access to your config.
  Do not put secrets in remote config — anyone with the app can read it.
- `clientKey` is a shared value compiled into the app. It keeps casual
  traffic away from your Worker but is **not** a secret. Combine with
  [Cloudflare rate limiting](https://developers.cloudflare.com/waf/rate-limiting-rules/)
  if you need abuse protection.
- The library never logs the client key or config values.

## Platform notes

- **Auto Backup:** the cache file `shared_prefs/cloudflare_worker_kv.xml` is
  included in Auto Backup, so a restored app starts with the last config it
  saw. That is harmless, but you can exclude it in your backup rules:
  `<exclude domain="sharedpref" path="cloudflare_worker_kv.xml" />`.
- **Local development:** Android blocks plain HTTP by default. To reach
  `wrangler dev` (`http://10.0.2.2:8787` from the emulator), allow cleartext
  for that host in a debug-only
  [network security config](https://developer.android.com/privacy-and-security/security-config),
  like [the example](example/src/debug/res/xml/network_security_config.xml).
- **R8 / ProGuard:** no rules are needed.
- **Java:** constructors, getters, `info` and
  `RemoteConfigSettings.Builder().setMinimumFetchIntervalInSeconds(…)` work
  from Java. `initialize`, `fetch`, `activate` and the other suspend
  functions are meant for Kotlin; from Java, call them through a small Kotlin
  wrapper that returns a future or takes a callback.

## HTTP contract

The request, the responses and the client behaviour are specified in
[`spec/README.md`](../spec/README.md):

```
GET {endpoint}/v1/config?template={template}
  Request headers:  X-Client-Key (optional), If-None-Match (optional)
  200  {"version": "<opaque>", "entries": {"key": "value", ...}}   + ETag header
  304  when If-None-Match matches
  401/403 bad client key · 429 rate limited (Retry-After) · 5xx errors
```

## Example app

```bash
cd android
./gradlew :example:installDebug -PCF_CONFIG_ENDPOINT=https://<worker>.<subdomain>.workers.dev
# Optional: -PCF_CLIENT_KEY=... ; the CF_CONFIG_ENDPOINT / CF_CLIENT_KEY
# environment variables work too. With `wrangler dev` on the emulator:
./gradlew :example:installDebug -PCF_CONFIG_ENDPOINT=http://10.0.2.2:8787
```

## Running the tests

Requires JDK 17 or newer (Android Studio's bundled JDK works) and the
Android SDK. Gradle finds the SDK through `ANDROID_HOME` or through
`android/local.properties`. Android Studio creates that git-ignored file when
it opens the project; from a plain terminal, create it yourself:

```bash
cd android
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties   # macOS default SDK location
./gradlew :cloudflare-worker-kv:testDebugUnitTest
```

Without it, Gradle fails with `SDK location not found`.

The unit tests run on the JVM and include the shared fixtures, read from
[`../spec/fixtures`](../spec/fixtures/) in the repository checkout. One
instrumented test checks the default storage against the real
`SharedPreferences`:

```bash
./gradlew :cloudflare-worker-kv:connectedDebugAndroidTest   # needs a device or emulator
```

## Roadmap

- `addOnConfigUpdateListener` (polling + `ETag`)
- Conditional values (platform, app version, percentage rollout)
