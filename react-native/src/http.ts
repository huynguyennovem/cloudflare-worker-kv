import { describe } from './log';
import { RemoteConfigError } from './remoteConfigError';

/** The request options passed to a {@link FetchLike} function. */
export interface FetchRequestInit {
  method: 'GET';
  headers: Record<string, string>;
  signal?: AbortSignal | undefined;
}

/** The subset of a fetch `Response` that the client reads. */
export interface FetchResponseLike {
  readonly status: number;
  readonly statusText?: string;
  /** Header lookup; must be case-insensitive, like `Headers#get`. */
  readonly headers: { get(name: string): string | null };
  text(): Promise<string>;
}

/**
 * A `fetch`-compatible function. The global `fetch` of React Native, Expo,
 * browsers and Node.js all qualify.
 */
export type FetchLike = (url: string, init: FetchRequestInit) => Promise<FetchResponseLike>;

/** A complete response: status, headers and the body read as text. */
export interface HttpResponse {
  readonly status: number;
  readonly statusText: string;
  readonly headers: { get(name: string): string | null };
  readonly body: string;
}

/** The largest delay `setTimeout` supports (2^31 - 1 ms). */
const MAX_TIMER_DELAY = 2_147_483_647;

/**
 * The default {@link FetchLike}: the global `fetch`, looked up at call time
 * (so polyfills and test mocks installed later are honoured) and called
 * unbound-safe (avoids "Illegal invocation" in browsers).
 */
export const globalFetch: FetchLike = (url, init) => {
  const requestInit: RequestInit = { method: init.method, headers: init.headers };
  if (init.signal !== undefined) requestInit.signal = init.signal;
  return globalThis.fetch(url, requestInit);
};

/**
 * Sends a GET request and reads the body, failing with a `timeout`
 * {@link RemoteConfigError} when the whole exchange (including reading the
 * body) takes longer than `timeoutMillis`, and with `network-error` when the
 * request or the body read fails.
 *
 * The `cache` option is deliberately not set: React Native's fetch polyfill
 * turns `no-store` / `no-cache` into an extra `_=<timestamp>` query parameter.
 */
export async function sendWithTimeout(
  fetchFn: FetchLike,
  url: string,
  headers: Record<string, string>,
  timeoutMillis: number,
): Promise<HttpResponse> {
  const controller = typeof AbortController === 'function' ? new AbortController() : undefined;
  let timedOut = false;

  const request = (async (): Promise<HttpResponse> => {
    const init: FetchRequestInit = { method: 'GET', headers };
    if (controller !== undefined) init.signal = controller.signal;
    const response = await fetchFn(url, init);
    const body = await response.text();
    return {
      status: response.status,
      statusText: response.statusText ?? '',
      headers: response.headers,
      body,
    };
  })();
  // After a timeout nobody awaits `request` any more. Promise.race below
  // already subscribes to it, but mark its late rejection (usually an
  // AbortError) as handled explicitly so it can never surface as unhandled.
  request.catch(() => {});

  let rejectTimeout: (reason: unknown) => void = () => {};
  const timeout = new Promise<never>((_, reject) => {
    rejectTimeout = reject;
  });
  const timer = setTimeout(
    () => {
      timedOut = true;
      controller?.abort();
      rejectTimeout(new Error(`Timed out after ${timeoutMillis} ms.`));
    },
    Math.min(Math.max(timeoutMillis, 0), MAX_TIMER_DELAY),
  );

  try {
    return await Promise.race([request, timeout]);
  } catch (error) {
    if (timedOut) {
      throw new RemoteConfigError('timeout', `No response within ${timeoutMillis} ms.`);
    }
    throw new RemoteConfigError('network-error', `Request to ${url} failed: ${describe(error)}`, {
      cause: error,
    });
  } finally {
    clearTimeout(timer);
  }
}
