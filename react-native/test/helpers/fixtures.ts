import { readFileSync } from 'node:fs';

/**
 * Reads the `cases` of a shared fixture from the repository checkout
 * (spec/fixtures), never from a published package.
 */
export function loadCases<T>(file: string): T[] {
  const url = new URL(`../../../spec/fixtures/${file}`, import.meta.url);
  const json = JSON.parse(readFileSync(url, 'utf8')) as { cases: T[] };
  return json.cases;
}
