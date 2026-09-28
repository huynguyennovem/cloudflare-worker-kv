# react-native-cloudflare-worker-kv

Remote config for React Native and Expo, backed by **Cloudflare Workers KV**.

- In-app defaults, `fetch` / `activate` / `fetchAndActivate`
- Typed getters: `getString`, `getNumber`, `getBoolean`, `getValue`, `getAll`
- Settings with `fetchTimeoutMillis` and `minimumFetchIntervalMillis`
- Offline cache: the last activated config is restored on the next launch
- Bandwidth-friendly: `ETag` / `304 Not Modified`
- Pure TypeScript, no native code: works in Expo Go, bare React Native and on
  the web
- An API modelled on `@react-native-firebase/remote-config`

## How it works

![Your app sends GET /v1/config?template=default to the Cloudflare Worker, which reads Workers KV and replies 200 {version, entries} or 304](https://raw.githubusercontent.com/huynguyennovem/cloudflare-worker-kv/main/assets/how-it-works.svg)

The package talks to a small read-only Cloudflare Worker, so your app never
holds a Cloudflare API token. The Worker, and how to deploy it against your KV
namespace, lives in the
[`worker/` module](https://github.com/huynguyennovem/cloudflare-worker-kv/tree/main/worker)
of this repository. Any backend that implements the
[HTTP contract](https://github.com/huynguyennovem/cloudflare-worker-kv/blob/main/spec/README.md)
works too.

## Getting started

You need the URL of a deployed Worker, e.g.
`https://my-config.<subdomain>.workers.dev`: `npm run deploy` prints it, and
the Cloudflare dashboard lists it under **Workers & Pages → your Worker →
Settings → Domains & Routes**
([details](https://github.com/huynguyennovem/cloudflare-worker-kv/blob/main/worker/README.md#find-the-worker-url)).

```bash
npx expo install react-native-cloudflare-worker-kv @react-native-async-storage/async-storage
```

`@react-native-async-storage/async-storage` (v1, v2 or v3) is a peer
dependency: it stores the cache. Without Expo, install both with npm or yarn
and run `pod install` for iOS.

```ts
import {
  CloudflareRemoteConfig,
  isRemoteConfigError,
} from 'react-native-cloudflare-worker-kv';

export async function setUpRemoteConfig(): Promise<void> {
  const remoteConfig = await CloudflareRemoteConfig.initialize({
    endpoint: 'https://my-config.<subdomain>.workers.dev',
    clientKey: 'optional-client-key', // only if the Worker sets CLIENT_KEY
  });
  await remoteConfig.setConfigSettings({
    fetchTimeoutMillis: 10_000,
    minimumFetchIntervalMillis: 3_600_000, // 1 hour; use 0 during development
  });
  await remoteConfig.setDefaults({
    welcome_message: 'Hello',
    max_items: 10,
    new_checkout_enabled: false,
  });

  try {
    await remoteConfig.fetchAndActivate();
  } catch (e) {
    // Offline, timeout, ... cached or default values are still available.
    if (isRemoteConfigError(e)) console.warn(`Remote config fetch failed: ${e.code}`);
  }
}

// Anywhere in the app, once initialize() has resolved:
const rc = CloudflareRemoteConfig.instance;
const maxItems = rc.getNumber('max_items');
const newCheckout = rc.getBoolean('new_checkout_enabled');
```

Values are delivered as strings and converted by the typed getters. A
parameter stored as a JSON object or array arrives as JSON text:

```ts
const units = JSON.parse(rc.getString('ad_units')) as Record<string, string>;
```

`getNumber` parses any decimal number; `getValue(key).asInteger()` accepts
only integers, like `getInt` in the other SDKs (`'10.0'` gives `0`).

See [`example/`](https://github.com/huynguyennovem/cloudflare-worker-kv/tree/main/react-native/example)
for a complete Expo app.

### Migrating from @react-native-firebase/remote-config

| @react-native-firebase/remote-config | react-native-cloudflare-worker-kv |
| --- | --- |
| `remoteConfig()` / `getRemoteConfig()` | `CloudflareRemoteConfig.instance` (after `initialize({ endpoint })`) |
| `setConfigSettings({ fetchTimeMillis, minimumFetchIntervalMillis })` | `setConfigSettings({ fetchTimeoutMillis, minimumFetchIntervalMillis })`; omitted fields go back to their defaults |
| `setDefaults(object)` | same; objects and arrays are stored as JSON |
| `setDefaultsFromResource()` | not supported |
| `ensureInitialized()` | same (done by `initialize`) |
| `fetch(expirationDurationSeconds?)` | `fetch()` (uses `minimumFetchIntervalMillis`) |
| `activate()` / `fetchAndActivate()` | same |
| `getValue` / `getString` / `getNumber` / `getBoolean` / `getAll` | same |
| `asString()` / `asNumber()` / `asBoolean()` / `getSource()` | same, plus `asInteger()` |
| `fetchTimeMillis`, `lastFetchStatus`, `settings` | same |
| `LastFetchStatus` | same values: `no_fetch_yet`, `success`, `failure`, `throttled` |
| Native Firebase errors | `RemoteConfigError` (`code`, `statusCode`), `isRemoteConfigError()` |
| `onConfigUpdated` | not yet |
| Conditions, A/B testing, personalization | not supported |

## Behaviour

- **Value resolution:** activated remote value → default → static
  (`''`, `0`, `false`). `getValue(key).getSource()` tells you which
  (`'remote'`, `'default'` or `'static'`).
- **Conversions:** `asBoolean()` is `true` for `1, true, t, yes, y, on`
  (case-insensitive). `asNumber()` / `asInteger()` return `0` when the value
  cannot be parsed. Values are trimmed first. Conversions never throw.
- **`fetch()`** never changes what the getters return; call `activate()`.
  Within `minimumFetchIntervalMillis` of the last successful fetch it
  resolves without a network request. Concurrent calls share one request.
- **`activate()`** resolves to `true` only when a fetched config differs from
  the active one.
- **Errors:** `fetch()` rejects with a `RemoteConfigError` whose `code` is
  `timeout`, `network-error`, `unauthorized`, `throttled`, `server-error` or
  `invalid-response`. A failed fetch never touches the active config.
  HTTP 429 sets `lastFetchStatus` to `throttled` and blocks fetches until
  `throttleEndTimeMillis` (from `Retry-After`, default 1 minute).
- **Timeout:** `fetchTimeoutMillis` limits the whole request, including
  reading the body; the request is aborted when it expires.
- **Freshness:** a change made in KV reaches the Worker after about 1–2
  minutes. The app picks it up on its next fetch, which
  `minimumFetchIntervalMillis` may delay.
- **Persistence:** active and pending config, `ETag`, settings and fetch
  status are stored with AsyncStorage. Pass your own `storage` to change that:
  anything with `getItem` / `setItem` / `removeItem` works, including the
  web's `localStorage`. Storage failures are logged with `console.warn` and
  never thrown. Defaults are not persisted — set them on every launch.
- **Before `initialize` resolves**, the synchronous getters only see the
  defaults. Await `initialize()` (or `ensureInitialized()`) before rendering
  values from the cache.
- **Multiple configs:** create extra instances with
  `new CloudflareRemoteConfig({ endpoint, template: 'staging' })` and await
  `ensureInitialized()`; each endpoint/template pair has its own cache.

## Security

- The Worker only exposes **read** access to your config.
  Do not put secrets in remote config — anyone with the app can read it.
- `clientKey` is a shared value compiled into the app. It keeps casual
  traffic away from your Worker but is **not** a secret. Combine with
  [Cloudflare rate limiting](https://developers.cloudflare.com/waf/rate-limiting-rules/)
  if you need abuse protection.

## Platform notes

- **Web:** the Worker sends CORS headers (including
  `Access-Control-Expose-Headers: ETag`), so no extra setup is needed. If you
  put another proxy in front of it, keep those headers, or every fetch
  downloads the full config.
- **Expo Go** only includes the AsyncStorage version bundled with its SDK:
  install it with `npx expo install`. If AsyncStorage's native module is
  missing, the client logs a warning and keeps working without a cache.
- **Jest:** the package ships ES modules only. `jest-expo` transforms it out
  of the box. With the bare `react-native` preset, add it to
  `transformIgnorePatterns`, e.g.
  `node_modules/(?!((jest-)?react-native|@react-native(-community)?|react-native-cloudflare-worker-kv)/)`.
  In tests, pass `storage: new InMemoryConfigStorage()` and a fake `fetch`
  instead of mocking AsyncStorage and the network.
- **Numbers** in `setDefaults` are printed as JavaScript numbers: `0.0`
  becomes `'0'` and `1e21` becomes `'1e+21'`.
- **Runtime:** the package needs `fetch`, `AbortController`, `Promise` and
  `Map`, which React Native, Expo, browsers and Node.js 18+ provide. It does
  not rely on React Native's incomplete `URL`.

## HTTP contract

```
GET {endpoint}/v1/config?template={template}
  Request headers:  X-Client-Key (optional), If-None-Match (optional)
  200  {"version": "<opaque>", "entries": {"key": "value", ...}}   + ETag header
  304  when If-None-Match matches
  401/403 bad client key · 429 rate limited (Retry-After) · 5xx errors
```

The full contract, including how clients handle each status, is in
[`spec/README.md`](https://github.com/huynguyennovem/cloudflare-worker-kv/blob/main/spec/README.md).
This package, the Flutter, Android and iOS SDKs all run the same test
fixtures from `spec/fixtures/`.

## Running the tests

```bash
npm install
npm run typecheck
npm test               # includes the shared fixtures in ../spec/fixtures
npm run build
npm run check:package  # publint + are-the-types-wrong
```
