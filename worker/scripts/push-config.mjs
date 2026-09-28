#!/usr/bin/env node
// Validates a JSON config file and writes it to Workers KV (CONFIG_SOURCE=json layout).
//
// Usage:
//   node scripts/push-config.mjs [file] [--template <name>] [--key <kv-key>] [--dry-run]
//
// Defaults: file = config.json, template = default. The key is the one the
// Worker reads: CONFIG_KEY from the "vars" of the Wrangler config (with
// {template} replaced), or config:<template> when CONFIG_KEY is not set.
// Use --key when CONFIG_KEY is managed in the dashboard instead. --dry-run
// prints where the file would go and writes nothing.
//
// Always writes to the real (remote) namespace. The namespace comes from the
// CONFIG_KV binding in the Wrangler config.
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";

const args = process.argv.slice(2);
const valueFlags = ["--template", "--key"];
const booleanFlags = ["--dry-run"];

function flagValue(name) {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
}

function fail(message) {
  console.error(`✖ ${message}`);
  process.exit(1);
}

for (const arg of args) {
  if (arg.startsWith("--") && !valueFlags.includes(arg) && !booleanFlags.includes(arg)) {
    fail(`Unknown option ${arg}.`);
  }
}
for (const flag of valueFlags) {
  if (args.includes(flag) && (flagValue(flag) ?? "").startsWith("--")) fail(`${flag} needs a value.`);
  if (args.includes(flag) && flagValue(flag) === undefined) fail(`${flag} needs a value.`);
}

const template = flagValue("--template") ?? "default";
const file =
  args.find((a, i) => !a.startsWith("--") && !valueFlags.includes(args[i - 1])) ?? "config.json";
const dryRun = args.includes("--dry-run");

if (!/^[A-Za-z0-9_-]{1,64}$/.test(template)) {
  fail(`Invalid template "${template}". Use [A-Za-z0-9_-]{1,64}.`);
}
const explicitKey = flagValue("--key");
const { key, keySource } =
  explicitKey === undefined ? keyFromWranglerConfig(template) : { key: explicitKey, keySource: "--key" };
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

const summary = `${Object.keys(parsed).length} parameter(s) from ${file} to "${key}" (remote; key from ${keySource})`;
if (dryRun) {
  console.log(`→ Would write ${summary}. Dry run: nothing written.`);
  process.exit(0);
}

const wranglerArgs = [
  "wrangler", "kv", "key", "put", key,
  "--binding", "CONFIG_KV",
  "--path", file,
  "--remote",
];
console.log(`→ Writing ${summary}`);
execFileSync("npx", wranglerArgs, { stdio: "inherit" });
console.log("✔ Done. Remote KV changes can take up to ~60s to propagate globally.");

/**
 * The key the deployed Worker reads for `template`, from the same Wrangler
 * config file that `wrangler` itself uses (see settings.ts for the rules).
 */
function keyFromWranglerConfig(template) {
  const path = findWranglerConfig(process.cwd());
  if (path === undefined) {
    fail("No Wrangler config found. Run `npm run config:push` in worker/, or pass --key.");
  }
  const name = basename(path);
  if (name.endsWith(".toml")) {
    fail(`Cannot read CONFIG_KEY from ${name}. Pass --key with the key your Worker reads.`);
  }

  let config;
  try {
    config = parseJsonc(readFileSync(path, "utf8"));
  } catch (e) {
    fail(`Cannot parse ${path}: ${e.message}`);
  }
  const vars = config?.vars ?? {};

  if (String(vars.CONFIG_SOURCE ?? "").trim().toLowerCase() === "keys") {
    fail(
      `${name} sets CONFIG_SOURCE=keys: the Worker reads one KV key per parameter, not one JSON ` +
        "object. Use `wrangler kv bulk put` (see README §6), or pass --key to write the object anyway.",
    );
  }
  if (vars.CONFIG_KEY === undefined) {
    if (config.keep_vars === true) {
      console.warn(
        `! ${name} has keep_vars: if CONFIG_KEY is set in the dashboard, pass --key with that value.`,
      );
    }
    return { key: `config:${template}`, keySource: `the default, no CONFIG_KEY in ${name}` };
  }
  if (typeof vars.CONFIG_KEY !== "string" || vars.CONFIG_KEY.trim() === "") {
    fail(`CONFIG_KEY in ${name} must be a non-empty string.`);
  }
  return { key: vars.CONFIG_KEY.split("{template}").join(template), keySource: `CONFIG_KEY in ${name}` };
}

/** Finds the config file like Wrangler: wrangler.json, .jsonc, .toml, searching up from `dir`. */
function findWranglerConfig(dir) {
  for (const name of ["wrangler.json", "wrangler.jsonc", "wrangler.toml"]) {
    for (let current = resolve(dir); ; current = dirname(current)) {
      const path = join(current, name);
      if (existsSync(path)) return path;
      if (dirname(current) === current) break;
    }
  }
  return undefined;
}

/** Parses JSON with comments and trailing commas (the wrangler.jsonc format). */
function parseJsonc(text) {
  const string = String.raw`"(?:\\.|[^"\\])*"`;
  const withoutComments = text.replace(
    new RegExp(String.raw`(${string})|//[^\n]*|/\*[\s\S]*?\*/`, "g"),
    (match, str) => str ?? (match.startsWith("/*") ? " " : ""),
  );
  const withoutTrailingCommas = withoutComments.replace(
    new RegExp(String.raw`(${string})|,(\s*[}\]])`, "g"),
    (match, str, closing) => str ?? closing,
  );
  return JSON.parse(withoutTrailingCommas);
}
