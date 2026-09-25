# cloudflare_worker_kv example

Shows remote config values, their source and the fetch status.

It needs a deployed Worker (see the
[`worker/` module](https://github.com/huynguyennovem/cloudflare-worker-kv-flutter/tree/main/worker)).
Pass its URL at build time:

```bash
flutter run \
  --dart-define=CF_CONFIG_ENDPOINT=https://<worker>.<subdomain>.workers.dev \
  --dart-define=CF_CLIENT_KEY=your-client-key   # only if the Worker sets CLIENT_KEY
```

Without `CF_CONFIG_ENDPOINT` the app shows this instruction instead.
Tap **Fetch & activate** to load the latest config. The example sets
`minimumFetchInterval` to zero, so every tap reaches the Worker.
