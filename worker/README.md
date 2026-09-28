# Remote config Worker

A Cloudflare Worker that reads config from a Workers KV namespace and serves
it, read-only, to the client SDKs of this repository
([Flutter](../flutter/README.md), [React Native](../react-native/README.md),
[Android](../android/README.md), [iOS](../ios/README.md)) or any other client
of the [HTTP contract](../spec/README.md). It works with a new namespace or
one you already have, with data in your own layout. Why the app goes through a
Worker instead of reading KV directly: see the
[FAQ](../README.md#why-not-read-workers-kv-directly-from-the-app).

- [1. Before you start](#1-before-you-start)
- [2. Describe your data](#2-describe-your-data)
- [3. Variables reference](#3-variables-reference)
- [4. Deploy with Wrangler](#4-deploy-with-wrangler)
- [5. Verify](#5-verify)
- [6. Publishing and updating data](#6-publishing-and-updating-data)
- [7. Day-to-day in the Cloudflare dashboard](#7-day-to-day-in-the-cloudflare-dashboard)
- [8. Costs, limits and freshness](#8-costs-limits-and-freshness)
- [9. Troubleshooting](#9-troubleshooting)
- [10. HTTP API](#10-http-api)
- [11. Development](#11-development)

## 1. Before you start

1. A Cloudflare account. The Free plan is enough to start.
2. A KV namespace. Use an existing one, or create one:
   - Dashboard: *Storage & databases* → *Workers KV* → *Create*.
   - CLI: `npx wrangler kv namespace create CONFIG_KV`.

   Find its ID under *Storage & databases* → *Workers KV* → your namespace →
   *Metrics* → *Instance Detail*, or with `npx wrangler kv namespace list`.
3. Node.js, to run Wrangler (Cloudflare's command-line tool) from this
   folder.

**Already created a Worker in the dashboard?** Reuse it: set `name` in
`wrangler.jsonc` to **that Worker's exact name**, otherwise Wrangler creates a
second Worker. The Worker's existing code is **replaced**. This Worker answers
only `/v1/config` and returns `404` for every other path. If the Worker does
other work you need to keep, create a separate Worker for config.

## 2. Describe your data

The Worker reads the namespace bound as **`CONFIG_KV`**. The binding's
variable name must be `CONFIG_KV`; the namespace's own name (title) does not
matter, and other Workers may bind the same namespace under other names.

### Empty or new namespace → keep the defaults

No variables needed. Store one JSON object per template under
`config:<template>`, e.g. `config:default` (see [§6](#6-publishing-and-updating-data)).

The `wrangler.jsonc` in this repository sets `CONFIG_KEY` to `config`, so as
shipped, the Worker reads the key `config` for every template. Remove that
variable to use the default.

### One key holds a JSON object → `json` layout

```
app-config   {"welcome_message": "Hello", "max_items": 20, "beta": true}
```

| Variable | Value |
| --- | --- |
| `CONFIG_KEY` | `app-config` |

Per-environment keys such as `app-config-prod` / `app-config-staging`: set
`CONFIG_KEY=app-config-{template}` and set the template to `prod` in the app
SDK.

### One key per parameter → `keys` layout

```
rc:welcome_message       Hello
rc:max_items             20
rc:beta                  true
session:abc123           (unrelated data — ignored)
```

| Variable | Value |
| --- | --- |
| `CONFIG_SOURCE` | `keys` |
| `KEY_PREFIX` | `rc:` |

The app receives `welcome_message`, `max_items` and `beta` (prefix stripped).
`KEY_PREFIX` supports `{template}` too, e.g. `rc:{template}:` for
`rc:prod:max_items`. If values were written JSON-encoded (`"Hello"` with
quotes), add `VALUE_FORMAT=json`.

> Always use a dedicated prefix. An empty `KEY_PREFIX` exposes **every** key
> in the namespace to anyone who has the app.

### Which layout should I use?

| | `json` | `keys` |
| --- | --- | --- |
| KV cost per cache miss | 1 read | 1 `list` + 1 read per parameter |
| Free plan (1,000 lists + 100,000 reads/day) | fine | can run out of quota under load |
| Atomic multi-parameter updates | yes | no (keys propagate independently) |
| Max parameters | value size (25 MiB) | 1,000 |

Prefer `json` when you can; use `keys` to serve data that already exists in
that shape.

Values of any JSON type are accepted. The app receives them as strings:
`20` → `"20"`, objects and arrays → JSON text. `null` values are
dropped.

## 3. Variables reference

All optional. Set them in `vars` in `wrangler.jsonc`, except `CLIENT_KEY`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CONFIG_SOURCE` | `json` | `json`: one KV value holds a JSON object. `keys`: one KV key per parameter. |
| `CONFIG_KEY` | `config:{template}` | `json` layout: KV key to read. `{template}` is replaced by the requested template. |
| `KEY_PREFIX` | *(empty)* | `keys` layout: only keys with this prefix are parameters; the prefix is stripped. Supports `{template}`. |
| `VALUE_FORMAT` | `raw` | `keys` layout: `raw` keeps values as stored; `json` decodes JSON values (non-JSON text is kept). |
| `CACHE_TTL` | `60` | Seconds. KV `cacheTtl` and, for `keys`, the in-memory cache of the assembled result. Integer ≥ 30. |
| `CLIENT_KEY` | — | Store as a **secret**. When set, clients must send a matching `X-Client-Key`. |

An invalid value returns `500 {"error":"worker_misconfigured"}`, and the
message names the variable.

## 4. Deploy with Wrangler

```bash
npm install
npx wrangler login
npx wrangler kv namespace list   # [{ "id": "…", "title": "…" }]
```

Edit `wrangler.jsonc`:

```jsonc
{
  "name": "my-config",                  // existing Worker: use its exact name
  "main": "src/index.ts",
  "compatibility_date": "2026-08-01",
  "observability": { "enabled": true },
  "kv_namespaces": [
    { "binding": "CONFIG_KV", "id": "<your namespace id>" }
  ],
  "vars": {                             // only if §2 needs any
    "CONFIG_KEY": "app-config"
  }
}
```

```bash
npx wrangler secret put CLIENT_KEY   # optional
npm run deploy                        # prints the *.workers.dev URL
```

Things to know:

- **Keep the `id`.** Without it, `wrangler deploy` reuses a `CONFIG_KV`
  binding already on the deployed Worker. If there is none, it provisions a
  *new* namespace (`<worker>-config-kv`) instead of using yours.
- **Wrangler overwrites dashboard edits.** `wrangler deploy` replaces vars and
  bindings with the ones in `wrangler.jsonc`, so a KV binding added only in
  the dashboard is removed unless it is declared in `kv_namespaces`. Secrets
  are kept. `"keep_vars": true` keeps dashboard *variables*, not bindings.
- **Taking over a dashboard-created Worker.** If the change is destructive,
  `wrangler deploy` shows a diff between the dashboard and `wrangler.jsonc`
  and asks *Would you like to continue?* (no prompt in CI).
  - Answer **No**, and Wrangler offers to copy the dashboard values into
    `wrangler.jsonc`.
  - Accept, review with `git diff`, then deploy again. This keeps the
    variables and bindings you set by hand.
- **Don't put `CLIENT_KEY` in `vars`.** A variable with the same name as an
  existing secret triggers a warning. Continuing replaces the secret with a
  plain variable that anyone can read in the dashboard.
- **`workers_dev`:** when it is not in the file, Wrangler *enables* the
  `*.workers.dev` URL, even if you disabled it in the dashboard. Add
  `"workers_dev": false` to keep it off. Routes and custom domains set in the
  dashboard are left alone while `wrangler.jsonc` has no `routes`.
- **CI:** set `CLOUDFLARE_API_TOKEN` (and `CLOUDFLARE_ACCOUNT_ID` if the token
  can access several accounts) instead of `wrangler login`.

## 5. Verify

### Find the Worker URL

The SDKs call this URL the **endpoint**. The examples read it from
`CF_CONFIG_ENDPOINT` (Flutter, Android, iOS) or `EXPO_PUBLIC_CF_CONFIG_ENDPOINT`
(React Native). Get it in one of two ways:

- **From the deploy output.** `npm run deploy` prints it after the upload:

  ```
  Deployed cloudflare-worker-kv-config triggers (0.35 sec)
    https://cloudflare-worker-kv-config.<subdomain>.workers.dev
  ```

  The first part is the `name` in `wrangler.jsonc`; `<subdomain>` is your
  account's `workers.dev` subdomain. If the account has none yet, the first
  deploy asks you to register one.
- **From the dashboard.** Open **Workers & Pages**, select the Worker, then
  **Settings → Domains & Routes**. The `workers.dev` entry is the same URL. A
  custom domain listed there (`https://config.example.com`) works too.

Use the base URL only, such as `https://<worker>.<subdomain>.workers.dev`.
Leave out `/v1/config`: the SDKs append it, so an endpoint that already
ends in `/v1/config` gets `404 not_found`. With `"workers_dev": false` (see
§4) there is no `workers.dev` URL; use a custom domain instead.

### Check it

```bash
curl -i -H "X-Client-Key: <key>" "https://<worker>.<subdomain>.workers.dev/v1/config"
curl -i -H "X-Client-Key: <key>" "https://<worker>.<subdomain>.workers.dev/v1/config?template=staging"
```

Omit the header when `CLIENT_KEY` is not set. Expect `200` with your
parameters in `entries`. Resending the returned `ETag` as `If-None-Match`
gives `304`. Then point your app's SDK at the Worker URL (see
[Use it in your app](../README.md#getting-started)).

## 6. Publishing and updating data

**Changing data needs no redeploy.** The Worker reads KV on every request, so
an edited value reaches apps in about 1–2 minutes (see
[freshness](#8-costs-limits-and-freshness)). Redeploying does not make it
faster: the delay comes from KV propagation and caching, not from the Worker.
See [when to redeploy](#when-to-redeploy-the-worker) for the changes that do
need one.

Always pass `--remote` to `wrangler kv` commands. Without it, Wrangler writes
to a local copy that Cloudflare never sees. `npm run config:push` adds it for
you.

**`json` layout, in the dashboard:** *Storage & databases* → *Workers KV* →
namespace → *KV Pairs* → add an entry or edit the value.

**`json` layout, from the command line:** fetch the current value, edit it,
push it back. The push script checks that the file is a JSON object before
writing.

It writes to the key the Worker reads: `CONFIG_KEY` from `wrangler.jsonc`
with `{template}` replaced, or `config:<template>` when `CONFIG_KEY` is not
set. With this repository's `wrangler.jsonc`, that is `config`. Pass `--key`
when `CONFIG_KEY` is set in the dashboard instead of `wrangler.jsonc`.

```bash
npm run config:push -- config.local.json --dry-run            # prints the key, writes nothing
npx wrangler kv key get <key> --binding CONFIG_KV --remote > config.local.json
# edit config.local.json
npm run config:push -- config.local.json                      # -> the key the Worker reads
npm run config:push -- staging.local.json --template staging  # -> that key for template "staging"
npm run config:push -- config.local.json --key app-config     # -> any other key
```

`*.local.json` files are git-ignored. For a new namespace, start from
[`config.example.json`](config.example.json).

**`keys` layout:** edit one key at a time in the dashboard, or:

```bash
npx wrangler kv key put rc:max_items 30 --binding CONFIG_KV --remote
npx wrangler kv bulk put data.json --binding CONFIG_KV --remote
```

`data.json` is `[{"key": "rc:max_items", "value": "30"}]`; values must be
strings.

List what is stored with
`npx wrangler kv key list --binding CONFIG_KV --remote` (add `--prefix rc:`
to filter). KV allows 1 write per second per key, and the Free plan allows
1,000 writes per day.

### When to redeploy the Worker

| Change | Redeploy? |
| --- | --- |
| Edit a config value, or add or remove a parameter, in KV | No |
| Change a variable (`CONFIG_KEY`, `CONFIG_SOURCE`, `KEY_PREFIX`, `CACHE_TTL`, …) | Yes: edit `wrangler.jsonc`, then `npm run deploy`. |
| Point `CONFIG_KV` at another namespace | Yes: change the `id` in `wrangler.jsonc`, then `npm run deploy`. |
| Set or change the `CLIENT_KEY` secret | No: `npx wrangler secret put CLIENT_KEY` applies it immediately. |
| New Worker code | Yes: `npm run deploy`. |

## 7. Day-to-day in the Cloudflare dashboard

The Worker page (*Workers & Pages* → your Worker) has the tabs *Overview*,
*Metrics*, *Deployments*, *Observability*, *Domains* and *Settings*.

| Task | Where |
| --- | --- |
| Change a config value | *Storage & databases* → *Workers KV* → namespace → *KV Pairs* |
| Request volume and errors | Worker → *Metrics* |
| Per-request logs (500s, 401s, …) | Worker → *Observability* (enabled in `wrangler.jsonc`), or `npx wrangler tail` |
| Deployment history, roll back | Worker → *Deployments* |
| See variables, secrets, bindings | Worker → *Settings* (choose *Production*). Change them in `wrangler.jsonc` instead; the next deploy overwrites dashboard edits. |
| URL, `workers.dev` on/off, custom domain | Worker → *Domains* |
| KV usage against your quota | *Storage & databases* → *Workers KV* → namespace → *Metrics* |

## 8. Costs, limits and freshness

- **Freshness:** KV propagation (about 60 s, sometimes more), plus
  `CACHE_TTL`, plus (for `keys`) up to another `CACHE_TTL` from the in-memory
  cache, plus the app's `minimumFetchInterval`. Expect roughly 1–2 minutes
  from a write until a fetch sees it.
- **Billing:** reads are billed per key, including keys read in bulk. List
  operations are billed per call. The Free plan allows 100,000 reads and
  1,000 lists per day. The `keys` layout costs one list and N reads per cache
  miss, and every isolate/location has its own cache. That is roughly 1,000
  misses a day on the Free plan: lists run out first below 100 parameters,
  reads at or above 100. Raise `CACHE_TTL` (e.g. 300–900) or use the `json`
  layout if you approach the limits.
- **Limits:** at most 1,000 parameters in the `keys` layout (more returns
  `500 too_many_keys`). Key names are at most 512 bytes and values at most
  25 MiB.
- **Security:** the Worker is read-only, but anything it serves is public to
  your app's users. `CLIENT_KEY` ships inside the app and is not a secret.

## 9. Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Updates take a while to show | See [freshness](#8-costs-limits-and-freshness); set the SDK's `minimumFetchInterval` to zero while testing. |
| Written with `wrangler kv key put` but not visible | Missing `--remote`; the write went to a local copy. |
| Pushed new values, but the Worker still returns the old ones | The write went to a key the Worker doesn't read, e.g. `config:default` while `CONFIG_KEY` is `config`. `npx wrangler kv key list --binding CONFIG_KV --remote` lists the keys; `npm run config:push -- <file> --dry-run` shows the key the Worker reads. Push again, then delete the stray key. |
| `200` with empty `entries` | No key matches: wrong `CONFIG_KEY` / `KEY_PREFIX` / template, or the binding points at another namespace. With no variables set, the Worker reads `config:default`. |
| `401 unauthorized` | `CLIENT_KEY` is set and the `X-Client-Key` header is missing or different. |
| `500 worker_misconfigured` | Invalid variable value; the message says which. |
| `500 invalid_config` | `json` layout: the value is not a JSON object. |
| `500 too_many_keys` | `keys` layout: more than 1,000 keys match; narrow `KEY_PREFIX`. |
| `503 kv_unavailable` | KV error or exhausted quota (e.g. Free-plan lists). |
| Dashboard variables or bindings disappeared | `wrangler deploy` replaced them; declare them in `vars` / `kv_namespaces` (`keep_vars` keeps variables only). |
| A new, empty namespace (`<worker>-config-kv`) appeared | `wrangler.jsonc` had no `id`. |
| A second Worker appeared next to yours | `name` in `wrangler.jsonc` differs from your existing Worker's name. Fix it, redeploy, delete the extra Worker. |
| Deploy fails with `Incorrect type for map entry` | `src/index.ts` exports something besides `default`. |

## 10. HTTP API

`GET /v1/config?template=<name>` (template defaults to `default`,
`[A-Za-z0-9_-]{1,64}`)

| Status | When |
| ------ | ---- |
| 200 | `{"version": "<sha256>", "entries": {...}}` with `ETag` |
| 304 | `If-None-Match` matches the current version |
| 400 | invalid template name |
| 401 | `CLIENT_KEY` is set and `X-Client-Key` is missing or wrong |
| 404 / 405 | unknown route / method |
| 500 | `invalid_config`, `worker_misconfigured` or `too_many_keys` (see [§9](#9-troubleshooting)) |
| 503 | KV read failed |

A missing template returns `200` with empty `entries`. Responses carry CORS
headers, so web apps (Flutter web, React Native web) work without extra
setup. The full contract, including how clients handle each status, is in
[spec/README.md](../spec/README.md).

## 11. Development

```bash
npm install
npm test                 # unit tests in the Workers runtime
npm run typecheck
```

- The tests declare their own bindings in `vitest.config.ts`, so the
  deployment settings in `wrangler.jsonc` never affect them.
- `src/index.ts` must only export the default handler: workerd treats every
  named export of the entry module as an entrypoint. Put helpers in the other
  modules (`config.ts`, `settings.ts`, `sources.ts`, `payload.ts`).
