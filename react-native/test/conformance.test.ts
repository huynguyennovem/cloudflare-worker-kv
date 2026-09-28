// Runs the shared fixtures in ../spec/fixtures (spec/README.md §4) against this
// package. Every SDK runs the same files; the Flutter package is the reference.
import { describe, expect, test } from 'vitest';

import { RemoteConfigError, RemoteConfigValue } from '../src/index';
import { buildConfigUrl, WorkerClient } from '../src/workerClient';
import { loadCases } from './helpers/fixtures';

interface ValueCase {
  raw: string | null;
  string: string;
  bool: boolean;
  int: number;
  double: number;
}

interface UriCase {
  endpoint: string;
  template: string;
  expected?: string;
  error?: true;
}

interface ResponseCase {
  name: string;
  sentEtag: string | null;
  status: number;
  headers: Record<string, string>;
  body: string;
  expect:
    | { result: 'fetched'; version: string; etag: string | null; entries: Record<string, string> }
    | { result: 'notModified' }
    | {
        result?: undefined;
        error: string;
        statusCode: number;
        throttleSeconds?: number;
        messageContains?: string;
      };
}

describe('value-conversions.json', () => {
  const cases = loadCases<ValueCase>('value-conversions.json');

  test('has cases', () => {
    expect(cases.length).toBeGreaterThan(0);
  });

  for (const c of cases) {
    test(JSON.stringify(c.raw), () => {
      const value =
        c.raw === null
          ? new RemoteConfigValue(undefined, 'static')
          : new RemoteConfigValue(c.raw, 'remote');
      expect(value.asString()).toBe(c.string);
      expect(value.asBoolean()).toBe(c.bool);
      expect(value.asInteger()).toBe(c.int);
      expect(value.asNumber()).toBe(c.double);
    });
  }
});

describe('config-uri.json', () => {
  const cases = loadCases<UriCase>('config-uri.json');

  test('has cases', () => {
    expect(cases.length).toBeGreaterThan(0);
  });

  for (const c of cases) {
    test(`${c.endpoint} + ${c.template}`, () => {
      const build = (): string => buildConfigUrl(c.endpoint, c.template);
      if (c.error === true) {
        expect(build).toThrow(TypeError);
      } else {
        expect(build()).toBe(c.expected);
      }
    });
  }
});

describe('responses.json', () => {
  const now = Date.UTC(2026, 0, 1);
  const cases = loadCases<ResponseCase>('responses.json');

  test('has cases', () => {
    expect(cases.length).toBeGreaterThan(0);
  });

  for (const c of cases) {
    test(c.name, async () => {
      const nullBody = c.status === 101 || c.status === 204 || c.status === 205 || c.status === 304;
      const client = new WorkerClient({
        endpoint: 'https://cfg.example.com',
        template: 'default',
        fetch: () =>
          Promise.resolve(
            new Response(nullBody ? null : c.body, { status: c.status, headers: c.headers }),
          ),
        now: () => now,
      });
      const fetching = client.fetch({ etag: c.sentEtag ?? undefined, timeoutMillis: 5_000 });

      const expected = c.expect;
      if (expected.result === 'fetched') {
        const result = await fetching;
        expect(result.kind).toBe('fetched');
        if (result.kind !== 'fetched') return;
        expect(result.snapshot.version).toBe(expected.version);
        expect(result.etag).toBe(expected.etag ?? undefined);
        expect(Object.fromEntries(result.snapshot.entries)).toEqual(expected.entries);
      } else if (expected.result === 'notModified') {
        expect(await fetching).toEqual({ kind: 'notModified' });
      } else {
        const error: unknown = await fetching.then(
          () => {
            throw new Error('expected a rejection');
          },
          (e: unknown) => e,
        );
        expect(error).toBeInstanceOf(RemoteConfigError);
        const e = error as RemoteConfigError;
        expect(e.code).toBe(expected.error);
        expect(e.statusCode).toBe(expected.statusCode);
        expect(e.throttleEndTimeMillis).toBe(
          expected.throttleSeconds === undefined ? undefined : now + expected.throttleSeconds * 1000,
        );
        expect(e.message).toContain(expected.messageContains ?? '');
      }
    });
  }
});
