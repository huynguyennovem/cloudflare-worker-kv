# cloudflare_worker_kv example

Shows remote config values, their source and the fetch status.

## 1. Get the Worker URL

The example needs the URL of your deployed Worker, the **endpoint**. Deploy
the [`worker/` module](https://github.com/huynguyennovem/cloudflare-worker-kv/blob/main/worker/README.md#4-deploy-with-wrangler),
then copy the URL that `npm run deploy` prints:

```
Deployed cloudflare-worker-kv-config triggers (0.35 sec)
  https://cloudflare-worker-kv-config.<subdomain>.workers.dev
```

The same URL is in the Cloudflare dashboard: open **Workers & Pages**,
select the Worker, then **Settings → Domains & Routes**. See
[Find the Worker URL](https://github.com/huynguyennovem/cloudflare-worker-kv/blob/main/worker/README.md#find-the-worker-url)
for custom domains.

Use the base URL only, without `/v1/config` (the package appends it). Check
that the Worker answers before you run the app:

```bash
curl -i "https://<worker>.<subdomain>.workers.dev/v1/config"
```

Expect `200` with your parameters in `entries`. Add
`-H "X-Client-Key: <key>"` if the Worker sets `CLIENT_KEY`.

## 2. Run the example

The app reads the endpoint as `CF_CONFIG_ENDPOINT` at build time, so pass it
with `--dart-define`:

```bash
flutter run \
  --dart-define=CF_CONFIG_ENDPOINT=https://<worker>.<subdomain>.workers.dev \
  --dart-define=CF_CLIENT_KEY=your-client-key   # only if the Worker sets CLIENT_KEY
```

- **IDE:** add the same arguments to the run configuration. In VS Code, use
  `"args"` in `.vscode/launch.json`; in Android Studio, use **Run → Edit
  Configurations → Additional run args**.
- **Changing the value:** the value is compiled in, so after changing it,
  stop the app and run it again; hot reload and hot restart keep the old value.
- **Release builds:** they take the same flags, e.g.
  `flutter build apk --dart-define=CF_CONFIG_ENDPOINT=…`.
- **No endpoint:** without `CF_CONFIG_ENDPOINT`, the app shows how to pass it
  instead of the config.

### With a local Worker

Run `npx wrangler dev` in [`worker/`](https://github.com/huynguyennovem/cloudflare-worker-kv/tree/main/worker);
it listens on port 8787 and reads a local copy of KV. Put test data in it
under the key your `wrangler.jsonc` reads (`config` in this repository):

```bash
npx wrangler kv key put config '{"welcome_message":"Hello"}' --binding CONFIG_KV --local
```

The endpoint depends on where the app runs:

| Platform | `CF_CONFIG_ENDPOINT` |
| --- | --- |
| iOS simulator, web | `http://localhost:8787` |
| Android emulator | `http://10.0.2.2:8787` |

## What it shows

Tap **Fetch & activate** to load the latest config; the app also does it on
start. The example sets `minimumFetchInterval` to zero, so every tap reaches
the Worker.
