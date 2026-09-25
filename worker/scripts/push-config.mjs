#!/usr/bin/env node
// Validates a JSON config file and writes it to Workers KV (CONFIG_SOURCE=json layout).
//
// Usage:
//   node scripts/push-config.mjs [file] [--template <name>] [--key <kv-key>]
//
// Defaults: file = config.json, template = default, key = config:<template>.
// Always writes to the real (remote) namespace. Use --key when the Worker has a
// custom CONFIG_KEY (e.g. --key app-config). The namespace comes from the CONFIG_KV
// binding in wrangler.jsonc.
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const args = process.argv.slice(2);
const valueFlags = ["--template", "--key"];

function flagValue(name) {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
}

function fail(message) {
  console.error(`✖ ${message}`);
  process.exit(1);
}

for (const arg of args) {
  if (arg.startsWith("--") && !valueFlags.includes(arg)) fail(`Unknown option ${arg}.`);
}
for (const flag of valueFlags) {
  if (args.includes(flag) && (flagValue(flag) ?? "").startsWith("--")) fail(`${flag} needs a value.`);
  if (args.includes(flag) && flagValue(flag) === undefined) fail(`${flag} needs a value.`);
}

const template = flagValue("--template") ?? "default";
const file =
  args.find((a, i) => !a.startsWith("--") && !valueFlags.includes(args[i - 1])) ?? "config.json";

if (!/^[A-Za-z0-9_-]{1,64}$/.test(template)) {
  fail(`Invalid template "${template}". Use [A-Za-z0-9_-]{1,64}.`);
}
const key = flagValue("--key") ?? `config:${template}`;
if (key.trim() === "" || new TextEncoder().encode(key).length > 512) {
  fail(`Invalid KV key "${key}". Keys must be 1-512 bytes.`);
}

let parsed;
try {
  parsed = JSON.parse(readFileSync(file, "utf8"));
} catch (e) {
  fail(`Cannot read/parse ${file}: ${e.message}`);
}
if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
  fail(`${file} must contain a JSON object of parameters.`);
}

const wranglerArgs = [
  "wrangler", "kv", "key", "put", key,
  "--binding", "CONFIG_KV",
  "--path", file,
  "--remote",
];
console.log(`→ Writing ${Object.keys(parsed).length} parameter(s) from ${file} to "${key}" (remote)`);
execFileSync("npx", wranglerArgs, { stdio: "inherit" });
console.log("✔ Done. Remote KV changes can take up to ~60s to propagate globally.");
