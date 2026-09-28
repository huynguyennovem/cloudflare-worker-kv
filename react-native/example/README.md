# react-native-cloudflare-worker-kv example

An [Expo](https://expo.dev) (SDK 57) app that shows remote config values,
their source and the fetch status. It mirrors the
[Flutter example](../../flutter/example/lib/main.dart).

It needs a Worker, deployed or running locally (see the
[`worker/` module](../../worker/)).

## 1. Get the Worker URL

The example needs the URL of your deployed Worker, the **endpoint**. Deploy
the [`worker/` module](../../worker/README.md#4-deploy-with-wrangler), then
copy the URL that `npm run deploy` prints:

```
Deployed cloudflare-worker-kv-config triggers (0.35 sec)
  https://cloudflare-worker-kv-config.<subdomain>.workers.dev
```

The same URL is in the Cloudflare dashboard: open **Workers & Pages**,
select the Worker, then **Settings → Domains & Routes**. See
[Find the Worker URL](../../worker/README.md#find-the-worker-url) for custom
domains.

Use the base URL only, without `/v1/config` (the package appends it). Check
that the Worker answers before you run the app:

```bash
curl -i "https://<worker>.<subdomain>.workers.dev/v1/config"
```

Expect `200` with your parameters in `entries`. Add
`-H "X-Client-Key: <key>"` if the Worker sets `CLIENT_KEY`.

## 2. Run

The example uses the library straight from this repository: Metro resolves
`react-native-cloudflare-worker-kv` to `..` and reads its built `dist/`
(see [`metro.config.js`](metro.config.js)). Build the library first:

```bash
cd react-native
npm install
npm run build        # or `npm run dev` to rebuild on every change
cd example
npm install
```

Then pass the Worker URL, either in the environment:

```bash
EXPO_PUBLIC_CF_CONFIG_ENDPOINT=https://cloudflare-worker-kv-config.netshareoss.workers.dev npx expo start --ios
```

or in `.env.local` (ignored by git), copied from [`.env.example`](.env.example):

```bash
cp .env.example .env.local   # then edit it
npx expo start --clear --ios # or --android, or --web
```

Set `EXPO_PUBLIC_CF_CLIENT_KEY` too if the Worker sets `CLIENT_KEY`.
Without `EXPO_PUBLIC_CF_CONFIG_ENDPOINT` the app shows this instruction
instead.

- **Changing the value:** Expo inlines `EXPO_PUBLIC_*` variables when it
  bundles, and Metro caches the result. After creating or editing
  `.env.local`, restart with `npx expo start --clear`, or the app keeps the
  old value.
- **EAS Build:** `.env.local` is ignored by git, so EAS Build doesn't see it.
  Set `EXPO_PUBLIC_CF_CONFIG_ENDPOINT` in the build profile's `env` in
  `eas.json`, or as an EAS environment variable.

### With a local Worker

Run the Worker with `npx wrangler dev` in [`worker/`](../../worker/); it
listens on port 8787 and reads a local copy of KV. Put test data in it under
the key your `wrangler.jsonc` reads (`config` in this repository):

```bash
npx wrangler kv key put config '{"welcome_message":"Hello"}' --binding CONFIG_KV --local
```

The address depends on where the app runs:

| Platform | Endpoint |
| --- | --- |
| iOS simulator, web | `http://localhost:8787` |
| Android emulator | `http://10.0.2.2:8787` |

## What it shows

Tap **Fetch & activate** to load the latest config; the app also does it on
start. The snackbar says *New config activated*, *Config is up to date* or
*Fetch failed: &lt;code&gt;*. The example sets `minimumFetchIntervalMillis`
to zero, so every tap reaches the Worker.

The screen shows `welcome_message`, `max_items`, `discount_ratio` and
`new_checkout_enabled` (with in-app defaults), the fetch status, the last
fetch time, and every value with its source (`remote`, `default` or
`static`).

## Checks

```bash
npx tsc --noEmit
EXPO_PUBLIC_CF_CONFIG_ENDPOINT=https://example.invalid npx expo export -p web -p ios --output-dir /tmp/rn-export
```
