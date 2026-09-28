// Port of flutter/test/worker_client_test.dart, plus the timeout and body
// reading rules of spec/README.md §2.2.
import { afterEach, describe, expect, test, vi } from 'vitest';

import { RemoteConfigError } from '../src/index';
import type { FetchLike, FetchRequestInit, RemoteConfigErrorCode } from '../src/index';
import { buildConfigUrl, DEFAULT_THROTTLE_MILLIS, WorkerClient } from '../src/workerClient';

const endpoint = 'https://cfg.example.com';
const timeoutMillis = 5_000;
const T0 = Date.UTC(2026, 0, 1);

function clientFor(fetch: FetchLike, clientKey?: string): WorkerClient {
  return new WorkerClient({ endpoint, template: 'default', clientKey, fetch, now: () => T0 });
}

/** A fetch that always answers with `response()`. */
function respond(response: () => Response): FetchLike {
  return () => Promise.resolve(response());
}

async function rejection(promise: Promise<unknown>): Promise<RemoteConfigError> {
  const error = await promise.then(
    () => {
      throw new Error('expected a rejection');
    },
    (e: unknown) => e,
  );
  expect(error).toBeInstanceOf(RemoteConfigError);
  return error as RemoteConfigError;
}

async function expectCode(
  promise: Promise<unknown>,
  code: RemoteConfigErrorCode,
  statusCode?: number,
): Promise<RemoteConfigError> {
  const error = await rejection(promise);
  expect(error.code).toBe(code);
  expect(error.statusCode).toBe(statusCode);
  return error;
}

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('buildConfigUrl', () => {
  test('appends path and template', () => {
    expect(buildConfigUrl('https://a.dev', 'default')).toBe(
      'https://a.dev/v1/config?template=default',
    );
  });

  test('preserves path prefix, query and drops fragment', () => {
    expect(buildConfigUrl('https://a.dev/api/?x=1#frag', 'staging')).toBe(
      'https://a.dev/api/v1/config?x=1&template=staging',
    );
  });

  test('keeps a custom port', () => {
    expect(buildConfigUrl('https://config.example.com:8443', 'd')).toBe(
      'https://config.example.com:8443/v1/config?template=d',
    );
  });

  test('rejects relative URLs', () => {
    expect(() => buildConfigUrl('/config', 'd')).toThrow(TypeError);
  });

  test('replaces template in place and drops later duplicates', () => {
    expect(buildConfigUrl('https://a.dev/?a=1&template=old&b=2&template=older', 'new')).toBe(
      'https://a.dev/v1/config?a=1&template=new&b=2',
    );
    expect(buildConfigUrl('https://a.dev/?%74emplate=old', 'new')).toBe(
      'https://a.dev/v1/config?template=new',
    );
  });

  test('keeps the rest of the query verbatim and drops empty segments', () => {
    expect(buildConfigUrl('https://a.dev/p?q=a%20b&&flag&x=1+2&', 't')).toBe(
      'https://a.dev/p/v1/config?q=a%20b&flag&x=1+2&template=t',
    );
    expect(buildConfigUrl('https://a.dev?', 't')).toBe('https://a.dev/v1/config?template=t');
  });

  test('removes only one trailing slash', () => {
    expect(buildConfigUrl('https://a.dev/api//', 't')).toBe('https://a.dev/api//v1/config?template=t');
  });

  test('accepts userinfo, IPv6 hosts and custom schemes', () => {
    expect(buildConfigUrl('http://user:pw@[::1]:8787/x', 't')).toBe(
      'http://user:pw@[::1]:8787/x/v1/config?template=t',
    );
    expect(buildConfigUrl('http://10.0.2.2:8787', 't')).toBe('http://10.0.2.2:8787/v1/config?template=t');
  });

  test('rejects endpoints without a host', () => {
    for (const e of ['https://', 'https://:8080', 'https://user@', 'http://[/x', 'https:/a.dev', '']) {
      expect(() => buildConfigUrl(e, 't'), e).toThrow(TypeError);
    }
  });
});

test('sends headers and parses 200', async () => {
  let seenUrl = '';
  let seenInit: FetchRequestInit | undefined;
  const client = clientFor(async (url, init) => {
    seenUrl = url;
    seenInit = init;
    return new Response(
      JSON.stringify({
        version: 'v1',
        entries: { a: 'xin chào', n: 1, b: true, o: { k: 1 }, z: null },
      }),
      { status: 200, headers: { etag: '"v1"' } },
    );
  }, 'secret');

  const result = await client.fetch({ etag: '"v0"', timeoutMillis });

  expect(seenInit?.method).toBe('GET');
  expect(seenUrl).toBe('https://cfg.example.com/v1/config?template=default');
  expect(seenInit?.headers).toEqual({
    Accept: 'application/json',
    'X-Client-Key': 'secret',
    'If-None-Match': '"v0"',
  });
  // No `cache` option: React Native's fetch polyfill would add `_=<ts>` to the URL.
  expect(Object.keys(seenInit ?? {}).sort()).toEqual(['headers', 'method', 'signal']);
  expect(seenInit?.signal).toBeInstanceOf(AbortSignal);
  expect(result.kind).toBe('fetched');
  if (result.kind !== 'fetched') return;
  expect(result.etag).toBe('"v1"');
  expect(result.snapshot.version).toBe('v1');
  expect(Object.fromEntries(result.snapshot.entries)).toEqual({
    a: 'xin chào',
    n: '1',
    b: 'true',
    o: '{"k":1}',
  });
});

test('omits optional headers when not provided', async () => {
  let seen: FetchRequestInit | undefined;
  const client = clientFor(async (_url, init) => {
    seen = init;
    return new Response('{"version":"v","entries":{}}', { status: 200 });
  });
  await client.fetch({ timeoutMillis });
  expect(seen?.headers).toEqual({ Accept: 'application/json' });
});

test('sends an empty client key', async () => {
  let seen: FetchRequestInit | undefined;
  const client = clientFor(async (_url, init) => {
    seen = init;
    return new Response('{"entries":{}}', { status: 200 });
  }, '');
  await client.fetch({ timeoutMillis });
  expect(seen?.headers['X-Client-Key']).toBe('');
});

test('falls back to ETag when version is missing', async () => {
  const client = clientFor(
    respond(() => new Response('{"entries":{}}', { status: 200, headers: { etag: 'W/"abc"' } })),
  );
  const result = await client.fetch({ timeoutMillis });
  expect(result.kind === 'fetched' && result.snapshot.version).toBe('abc');
});

test('304 with etag -> not modified', async () => {
  const client = clientFor(respond(() => new Response(null, { status: 304 })));
  expect(await client.fetch({ etag: '"v"', timeoutMillis })).toEqual({ kind: 'notModified' });
});

test('304 without etag -> invalid-response', async () => {
  const client = clientFor(respond(() => new Response(null, { status: 304 })));
  await expectCode(client.fetch({ timeoutMillis }), 'invalid-response', 304);
});

test('malformed bodies -> invalid-response', async () => {
  for (const body of ['not json', '[]', '{"entries":[]}', '{}', 'null']) {
    const client = clientFor(respond(() => new Response(body, { status: 200 })));
    const error = await expectCode(client.fetch({ timeoutMillis }), 'invalid-response', 200);
    expect(error.message, body).toMatch(/^Malformed config payload: /);
  }
});

test('401 and 403 -> unauthorized', async () => {
  for (const status of [401, 403]) {
    const client = clientFor(respond(() => new Response('', { status })));
    await expectCode(client.fetch({ timeoutMillis }), 'unauthorized', status);
  }
});

test('429 -> throttled with Retry-After', async () => {
  const client = clientFor(
    respond(() => new Response('', { status: 429, headers: { 'retry-after': '120' } })),
  );
  const error = await expectCode(client.fetch({ timeoutMillis }), 'throttled', 429);
  expect(error.throttleEndTimeMillis).toBe(Date.UTC(2026, 0, 1, 0, 2));
});

test('429 without Retry-After uses default duration', async () => {
  const client = clientFor(respond(() => new Response('', { status: 429 })));
  const error = await expectCode(client.fetch({ timeoutMillis }), 'throttled', 429);
  expect(error.throttleEndTimeMillis).toBe(T0 + DEFAULT_THROTTLE_MILLIS);
});

test('5xx -> server-error with worker error code in message', async () => {
  const client = clientFor(
    respond(() => new Response('{"error":"invalid_config","message":"bad"}', { status: 500 })),
  );
  const error = await expectCode(client.fetch({ timeoutMillis }), 'server-error', 500);
  expect(error.message).toBe('Unexpected response: invalid_config - bad');
});

test('server-error falls back to the status text, then the status code', async () => {
  const withText = clientFor(
    respond(() => new Response('<html>Bad gateway</html>', { status: 502, statusText: 'Bad Gateway' })),
  );
  expect((await rejection(withText.fetch({ timeoutMillis }))).message).toBe(
    'Unexpected response: Bad Gateway',
  );
  const withoutText = clientFor(respond(() => new Response('{"error":7}', { status: 502 })));
  expect((await rejection(withoutText.fetch({ timeoutMillis }))).message).toBe(
    'Unexpected response: HTTP 502',
  );
});

test('network error -> network-error', async () => {
  const cause = new TypeError('Network request failed');
  const client = clientFor(() => Promise.reject(cause));
  const error = await expectCode(client.fetch({ timeoutMillis }), 'network-error');
  expect(error.cause).toBe(cause);
  expect(error.message).toBe(
    'Request to https://cfg.example.com/v1/config?template=default failed: TypeError: Network request failed',
  );
});

test('a synchronous throw from fetch -> network-error', async () => {
  const client = clientFor(() => {
    throw new TypeError('fetch is not a function');
  });
  await expectCode(client.fetch({ timeoutMillis }), 'network-error');
});

test('a body-read failure -> network-error', async () => {
  const client = clientFor(async () => ({
    status: 200,
    headers: new Headers(),
    text: () => Promise.reject(new TypeError('body stream failed')),
  }));
  const error = await expectCode(client.fetch({ timeoutMillis }), 'network-error');
  expect(error.cause).toBeInstanceOf(TypeError);
});

test('slow response -> timeout', async () => {
  const client = clientFor(() => new Promise(() => {})); // never completes
  const error = await expectCode(client.fetch({ timeoutMillis: 20 }), 'timeout');
  expect(error.message).toBe('No response within 20 ms.');
});

test('timeout aborts the signal', async () => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
  let signal: AbortSignal | undefined;
  const client = clientFor(
    (_url, init) =>
      new Promise((_resolve, reject) => {
        signal = init.signal;
        init.signal?.addEventListener('abort', () => {
          reject(new DOMException('The operation was aborted.', 'AbortError'));
        });
      }),
  );
  const fetching = expectCode(client.fetch({ timeoutMillis: 1_000 }), 'timeout');
  await vi.advanceTimersByTimeAsync(999);
  expect(signal?.aborted).toBe(false);
  await vi.advanceTimersByTimeAsync(1);
  await fetching;
  expect(signal?.aborted).toBe(true);
});

test('a timeout fires even when fetch ignores the signal', async () => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
  const client = clientFor(() => new Promise(() => {}));
  const fetching = expectCode(client.fetch({ timeoutMillis: 60_000 }), 'timeout');
  await vi.advanceTimersByTimeAsync(60_000);
  await fetching;
});

test('the timeout covers reading the body', async () => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
  const client = clientFor(async () => ({
    status: 200,
    headers: new Headers(),
    text: () => new Promise<string>(() => {}), // headers arrived, body never does
  }));
  const fetching = expectCode(client.fetch({ timeoutMillis: 500 }), 'timeout');
  await vi.advanceTimersByTimeAsync(500);
  await fetching;
});

test('no unhandled rejection after a timeout', async () => {
  const unhandled: unknown[] = [];
  const onUnhandled = (reason: unknown): void => {
    unhandled.push(reason);
  };
  process.on('unhandledRejection', onUnhandled);
  try {
    // Rejects shortly after the abort, when nobody awaits the request any more.
    const client = clientFor(
      (_url, init) =>
        new Promise((_resolve, reject) => {
          init.signal?.addEventListener('abort', () => {
            setTimeout(() => reject(new Error('late failure')), 5);
          });
        }),
    );
    await expectCode(client.fetch({ timeoutMillis: 10 }), 'timeout');
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(unhandled).toEqual([]);
  } finally {
    process.off('unhandledRejection', onUnhandled);
  }
});

test('the timer is cleared after a response', async () => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
  const client = clientFor(respond(() => new Response('{"entries":{}}', { status: 200 })));
  await client.fetch({ timeoutMillis });
  expect(vi.getTimerCount()).toBe(0);
});

test('huge timeouts are clamped to the largest timer delay', async () => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] });
  const client = clientFor(() => new Promise(() => {}));
  const fetching = expectCode(client.fetch({ timeoutMillis: Number.MAX_SAFE_INTEGER }), 'timeout');
  await vi.advanceTimersByTimeAsync(2_147_483_647);
  await fetching;
});

test('uses the global fetch at call time', async () => {
  const client = new WorkerClient({ endpoint, template: 'default' });
  const globalFetch = vi.fn(
    async (_url: string, _init: RequestInit) => new Response('{"entries":{"k":"v"}}', { status: 200 }),
  );
  vi.stubGlobal('fetch', globalFetch);
  const result = await client.fetch({ timeoutMillis });
  expect(result.kind).toBe('fetched');
  expect(globalFetch).toHaveBeenCalledTimes(1);
  expect(globalFetch.mock.calls[0]?.[0]).toBe('https://cfg.example.com/v1/config?template=default');
});

test('error toString is informative', () => {
  const e = new RemoteConfigError('server-error', 'boom', { statusCode: 502 });
  expect(e.toString()).toBe('RemoteConfigError[server-error] (HTTP 502): boom');
  expect(String(new RemoteConfigError('timeout', 'slow'))).toBe('RemoteConfigError[timeout]: slow');
});
