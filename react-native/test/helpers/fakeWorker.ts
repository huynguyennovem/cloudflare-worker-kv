import type { FetchLike, FetchRequestInit } from '../../src/index';

/** A request received by {@link FakeWorker}. */
export interface RecordedRequest {
  url: string;
  init: FetchRequestInit;
  headers: Record<string, string>;
}

/** Simulates the config Worker's HTTP contract in memory. */
export class FakeWorker {
  /** Current config served by the fake Worker. */
  entries: Record<string, string>;
  /** When set, requests must send a matching `X-Client-Key`. */
  clientKey: string | undefined;
  /** When set, called instead of the normal handling. */
  override: ((request: RecordedRequest) => Response | Promise<Response>) | undefined;
  /** Every request received, in order. */
  readonly requests: RecordedRequest[] = [];

  constructor(options: { entries?: Record<string, string>; clientKey?: string } = {}) {
    this.entries = { ...options.entries };
    this.clientKey = options.clientKey;
  }

  /** base64url of the JSON of the sorted `[key, value]` pairs. */
  get version(): string {
    const pairs = Object.keys(this.entries)
      .sort()
      .map((key) => [key, this.entries[key]]);
    return Buffer.from(JSON.stringify(pairs), 'utf8').toString('base64url');
  }

  /** Pass as the `fetch` option. */
  readonly fetch: FetchLike = (url, init) => this.handle(url, init);

  /** Handles one request like the real Worker would. */
  async handle(url: string, init: FetchRequestInit): Promise<Response> {
    const request: RecordedRequest = { url, init, headers: { ...init.headers } };
    this.requests.push(request);
    if (this.override !== undefined) return this.override(request);
    if (this.clientKey !== undefined && request.headers['X-Client-Key'] !== this.clientKey) {
      return new Response('{"error":"unauthorized"}', { status: 401 });
    }
    const etag = `"${this.version}"`;
    if (request.headers['If-None-Match'] === etag) {
      return new Response(null, { status: 304, headers: { etag } });
    }
    return new Response(JSON.stringify({ version: this.version, entries: this.entries }), {
      status: 200,
      headers: { etag, 'content-type': 'application/json' },
    });
  }
}
