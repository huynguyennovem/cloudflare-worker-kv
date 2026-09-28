import { ConfigSnapshot, isJsonObject } from './configSnapshot';
import { globalFetch, sendWithTimeout } from './http';
import type { FetchLike, HttpResponse } from './http';
import { describe } from './log';
import { RemoteConfigError } from './remoteConfigError';

/** Path of the config endpoint, appended to the Worker endpoint's path. */
export const CONFIG_PATH = '/v1/config';

/** Used when a 429 response carries no usable `Retry-After` header. */
export const DEFAULT_THROTTLE_MILLIS = 60_000;

const TEMPLATE_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;
const URL_PATTERN = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(?:\?([^#]*))?(?:#.*)?$/;
const INTEGER_PATTERN = /^[+-]?\d+$/;

/** Result of {@link WorkerClient.fetch}. */
export type WorkerFetchResult =
  | {
      readonly kind: 'fetched';
      /** The fetched config. */
      readonly snapshot: ConfigSnapshot;
      /** The response `ETag` verbatim, sent back as `If-None-Match` next time. */
      readonly etag: string | undefined;
    }
  | { readonly kind: 'notModified' };

export interface WorkerClientOptions {
  endpoint: string;
  template: string;
  clientKey?: string | undefined;
  fetch?: FetchLike | undefined;
  now?: (() => number) | undefined;
}

/** Throws a `TypeError` unless `template` matches `[A-Za-z0-9_-]{1,64}`. */
export function checkTemplate(template: unknown): string {
  if (typeof template !== 'string' || !TEMPLATE_PATTERN.test(template)) {
    throw new TypeError(`template must match [A-Za-z0-9_-]{1,64}, got ${JSON.stringify(template)}.`);
  }
  return template;
}

/**
 * Builds `{endpoint}/v1/config?template={template}`.
 *
 * Removes one trailing `/` from the endpoint's path before appending
 * `/v1/config`, keeps the scheme, host, port and query verbatim, replaces an
 * existing `template` parameter in place (dropping later duplicates) or
 * appends one, and drops the fragment. Throws a `TypeError` when the endpoint
 * has no scheme or no host.
 *
 * Hand-rolled on purpose: React Native's `URL` is incomplete and accepts
 * relative URLs.
 */
export function buildConfigUrl(endpoint: string, template: string): string {
  const match = typeof endpoint === 'string' ? URL_PATTERN.exec(endpoint) : null;
  if (match === null || hostOf(match[2] ?? '') === '') {
    throw new TypeError(
      `endpoint must be an absolute URL with a scheme and a host, got ${JSON.stringify(endpoint)}.`,
    );
  }
  const scheme = match[1] ?? '';
  const authority = match[2] ?? '';
  let path = match[3] ?? '';
  const query = match[4];

  if (path.endsWith('/')) path = path.slice(0, -1);
  path += CONFIG_PATH;

  const segments: string[] = [];
  let replaced = false;
  for (const segment of (query ?? '').split('&')) {
    if (segment === '') continue;
    if (queryKey(segment) === 'template') {
      if (replaced) continue; // Drop later duplicates.
      replaced = true;
      segments.push(`template=${template}`);
    } else {
      segments.push(segment);
    }
  }
  if (!replaced) segments.push(`template=${template}`);

  return `${scheme}://${authority}${path}?${segments.join('&')}`;
}

/** The host of a URL authority (`user@host:port`), without userinfo and port. */
function hostOf(authority: string): string {
  const hostPort = authority.slice(authority.lastIndexOf('@') + 1);
  if (hostPort.startsWith('[')) {
    const end = hostPort.indexOf(']');
    return end === -1 ? '' : hostPort.slice(0, end + 1);
  }
  const colon = hostPort.indexOf(':');
  return colon === -1 ? hostPort : hostPort.slice(0, colon);
}

/** The decoded key of a `key=value` query segment. */
function queryKey(segment: string): string {
  const equals = segment.indexOf('=');
  const raw = (equals === -1 ? segment : segment.slice(0, equals)).replace(/\+/g, ' ');
  try {
    return decodeURIComponent(raw);
  } catch {
    return raw;
  }
}

/** Low-level HTTP client for the config Worker. */
export class WorkerClient {
  /** Template name sent as the `template` query parameter. */
  readonly template: string;
  /** Optional value for the `X-Client-Key` header. */
  readonly clientKey: string | undefined;
  /** Fully resolved URL of the config endpoint. */
  readonly configUrl: string;

  private readonly fetchFn: FetchLike;
  private readonly now: () => number;

  constructor(options: WorkerClientOptions) {
    this.template = checkTemplate(options.template);
    this.configUrl = buildConfigUrl(options.endpoint, this.template);
    this.clientKey = options.clientKey ?? undefined;
    this.fetchFn = options.fetch ?? globalFetch;
    this.now = options.now ?? Date.now;
  }

  /**
   * Fetches the config, sending `If-None-Match: etag` when `etag` is given.
   * Rejects with a {@link RemoteConfigError} on any failure.
   */
  async fetch(options: {
    etag?: string | undefined;
    timeoutMillis: number;
  }): Promise<WorkerFetchResult> {
    const { etag, timeoutMillis } = options;
    const headers: Record<string, string> = { Accept: 'application/json' };
    if (this.clientKey !== undefined) headers['X-Client-Key'] = this.clientKey;
    if (etag !== undefined) headers['If-None-Match'] = etag;

    const response = await sendWithTimeout(this.fetchFn, this.configUrl, headers, timeoutMillis);

    const status = response.status;
    if (status === 304) {
      if (etag === undefined) {
        throw new RemoteConfigError(
          'invalid-response',
          'Received 304 for an unconditional request.',
          { statusCode: 304 },
        );
      }
      return { kind: 'notModified' };
    }
    if (status === 200) {
      const responseEtag = response.headers.get('etag') ?? undefined;
      try {
        const snapshot = ConfigSnapshot.fromJson(
          JSON.parse(response.body),
          stripEtag(responseEtag),
        );
        return { kind: 'fetched', snapshot, etag: responseEtag };
      } catch (error) {
        throw new RemoteConfigError(
          'invalid-response',
          `Malformed config payload: ${error instanceof Error ? error.message : describe(error)}`,
          { statusCode: status, cause: error },
        );
      }
    }
    if (status === 401 || status === 403) {
      throw new RemoteConfigError('unauthorized', 'The Worker rejected the client key.', {
        statusCode: status,
      });
    }
    if (status === 429) {
      const retryAfterMillis = parseRetryAfter(response.headers.get('retry-after'));
      throw new RemoteConfigError('throttled', 'Fetch is rate limited.', {
        statusCode: status,
        throttleEndTimeMillis: this.now() + retryAfterMillis,
      });
    }
    throw new RemoteConfigError('server-error', `Unexpected response: ${describeError(response)}`, {
      statusCode: status,
    });
  }
}

/** `Retry-After` in milliseconds: a trimmed non-negative integer of seconds, else 60 s. */
function parseRetryAfter(header: string | null): number {
  const trimmed = header?.trim() ?? '';
  if (!INTEGER_PATTERN.test(trimmed)) return DEFAULT_THROTTLE_MILLIS;
  const seconds = Number(trimmed);
  if (!Number.isSafeInteger(seconds) || seconds < 0) return DEFAULT_THROTTLE_MILLIS;
  return seconds * 1000;
}

/** The ETag without a `W/` prefix and surrounding quotes. */
function stripEtag(etag: string | undefined): string | undefined {
  if (etag === undefined) return undefined;
  let tag = etag.trim();
  if (tag.startsWith('W/')) tag = tag.slice(2);
  if (tag.length >= 2 && tag.startsWith('"') && tag.endsWith('"')) tag = tag.slice(1, -1);
  return tag;
}

/** `error - message` from a JSON error body, else the status text. */
function describeError(response: HttpResponse): string {
  try {
    const body: unknown = JSON.parse(response.body);
    if (isJsonObject(body) && typeof body['error'] === 'string') {
      const message = body['message'];
      return `${body['error']}${typeof message === 'string' ? ` - ${message}` : ''}`;
    }
  } catch {
    // Fall through to the status text.
  }
  return response.statusText || `HTTP ${response.status}`;
}
