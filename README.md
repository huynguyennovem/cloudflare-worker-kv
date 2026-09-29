# Cloudflare Workers KV Remote Config for Flutter, React Native, Android and iOS

Remote config for mobile and web apps, stored in **Cloudflare Workers KV**:
in-app defaults, fetch and activate, typed getters and an offline cache.

This repository holds independent modules:

| Module | What it is | Docs |
| --- | --- | --- |
| [`worker/`](worker/) | The Cloudflare Worker that reads remote KV and serves it over HTTP | [worker/README.md](worker/README.md) |
| [`flutter/`](flutter/) | The `cloudflare_worker_kv` Flutter package ([pub.dev](https://pub.dev/packages/cloudflare_worker_kv)) | [flutter/README.md](flutter/README.md) |
| [`react-native/`](react-native/) | The `react-native-cloudflare-worker-kv` package for React Native and Expo ([npm](https://www.npmjs.com/package/react-native-cloudflare-worker-kv)) | [react-native/README.md](react-native/README.md) |
| [`android/`](android/) | The `io.github.huynguyennovem:cloudflare-worker-kv` Kotlin library ([Maven Central](https://central.sonatype.com/artifact/io.github.huynguyennovem/cloudflare-worker-kv)) | [android/README.md](android/README.md) |
| [`ios/`](ios/) | The `CloudflareWorkerKV` Swift package (Swift Package Manager) | [ios/README.md](ios/README.md) |
| [`spec/`](spec/) | The HTTP contract and client behaviour shared by all of them, with test fixtures | [spec/README.md](spec/README.md) |

The modules share only an HTTP contract
([`GET /v1/config`](spec/README.md#1-http-api)). Each one is built, tested and
released on its own. The client SDKs behave the same way on every platform;
the shared [test fixtures](spec/README.md#4-shared-test-fixtures) keep them
in line.

## How it works

![Your app sends GET /v1/config?template=default to the Cloudflare Worker, which reads Workers KV and replies 200 {version, entries} or 304](assets/how-it-works.svg)

- **Workers KV** stores the config: a new namespace, or one you already have
  with data in your own layout.
- **The Worker** only reads KV. It returns the parameters as strings, with an
  `ETag` so unchanged config costs a `304`. The app never holds a Cloudflare
  API token ([why this matters](#why-not-read-workers-kv-directly-from-the-app)).
- **The SDK** gives the app defaults, `fetch` / `activate`, typed getters and
  an offline cache.

## Getting started

1. **Put your config in Workers KV.** Store the simplest layout, one JSON
   object under one key, or describe your existing layout with a few
   variables. `npm run config:push` writes the file to the key the Worker
   reads (`config` with the `wrangler.jsonc` in this repository).
   See [worker: describe your data](worker/README.md#2-describe-your-data).
2. **Deploy the Worker** with Wrangler (`npm run deploy`). An existing Worker
   can be reused. Note the URL it prints: that is the endpoint your app uses.
   See [worker: deploy](worker/README.md#4-deploy-with-wrangler) and
   [find the Worker URL](worker/README.md#find-the-worker-url).
3. **Check the Worker.** Your parameters must appear in `entries`:

   ```bash
   curl -i "https://<worker>.<subdomain>.workers.dev/v1/config"
   ```

4. **Use it in your app.** Add the SDK for your platform and point it at the
   Worker URL:

   | Platform | Install | Guide |
   | --- | --- | --- |
   | Flutter | `flutter pub add cloudflare_worker_kv` | [flutter/README.md](flutter/README.md#getting-started) |
   | React Native / Expo | `npx expo install react-native-cloudflare-worker-kv @react-native-async-storage/async-storage` | [react-native/README.md](react-native/README.md) |
   | Android (Kotlin) | `implementation("io.github.huynguyennovem:cloudflare-worker-kv:0.1.0")` | [android/README.md](android/README.md) |
   | iOS / macOS (Swift) | Swift Package Manager: `https://github.com/huynguyennovem/cloudflare-worker-kv` | [ios/README.md](ios/README.md) |

   Any other client can call the Worker directly: see the
   [HTTP contract](spec/README.md).
5. **Change config.** Edit the value in KV. Apps see it about 1–2 minutes
   later, on their next fetch after `minimumFetchInterval`.
   See [worker: updating data](worker/README.md#6-publishing-and-updating-data).

## Troubleshooting

| Symptom | Where to look |
| --- | --- |
| `entries` is empty, or the Worker returns an error status | [worker: troubleshooting](worker/README.md#9-troubleshooting) |
| KV changed but the app did not | [worker: freshness](worker/README.md#8-costs-limits-and-freshness), then `minimumFetchInterval` in [spec: fetch and activate](spec/README.md#27-fetch-and-activate) |
| A fetch fails in the app (`timeout`, `network-error`, `unauthorized`, …) | [spec: response handling](spec/README.md#23-response-handling), then the SDK's README |

## Repository layout

```
README.md          this guide
spec/              HTTP contract, client behaviour, shared test fixtures
worker/            Cloudflare Worker (src/, test/, scripts/, wrangler.jsonc)
flutter/           Flutter package (pubspec.yaml, lib/, test/, example/)
react-native/      React Native package (src/, test/, example/)
android/           Android library and example app (Gradle project)
ios/               Swift package sources, tests and example app
Package.swift      Swift Package Manager manifest (points into ios/)
RELEASING.md       how each module is versioned and published
```

## FAQ

### Why not read Workers KV directly from the app?

Workers KV has no public read endpoint. Outside a Worker, the only way to read
it is the [Cloudflare REST API](https://developers.cloudflare.com/kv/api/read-key-value-pairs/),
which requires an API token. Reading KV from the app means shipping that
token inside the app:

| Problem | Consequence |
| --- | --- |
| The token ships with the app | Anyone can extract it from an APK/IPA or from the JavaScript of a web or React Native build. KV permissions on API tokens cover the whole account, so it opens every namespace, and a token with write access lets anyone change your config. Replacing it needs a new app release. |
| One rate limit for all users | The Cloudflare API allows [1,200 requests per 5 minutes per user](https://developers.cloudflare.com/fundamentals/api/reference/limits/). Every install of the app shares it, together with your own dashboard and Wrangler use. Past the limit, all API calls are blocked for 5 minutes. |
| No web support | The API sends no CORS headers, so browsers block the request (Flutter web, React Native web). |
| No caching or change detection | Every fetch downloads the full value: no `ETag` / `304`, no edge cache, and one request per parameter with the `keys` layout. |

The Worker removes each of these. It reads KV through a binding, so the app
holds no credentials, and it exposes only the configured key or prefix,
read-only. It caches reads at the edge, returns all parameters in one response
with an `ETag`, and sends CORS headers. The Workers Free plan includes 100,000
requests per day.

## License

MIT, see [LICENSE](LICENSE).
