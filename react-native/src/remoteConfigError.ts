/**
 * Why a fetch failed:
 *
 * - `timeout`: no complete response within `fetchTimeoutMillis`.
 * - `network-error`: the request failed at the network layer.
 * - `unauthorized`: the Worker rejected the client key (HTTP 401/403).
 * - `throttled`: fetching is rate limited (HTTP 429); see `throttleEndTimeMillis`.
 * - `server-error`: the Worker responded with an unexpected HTTP status.
 * - `invalid-response`: the response is not a valid config payload.
 */
export type RemoteConfigErrorCode =
  | 'timeout'
  | 'network-error'
  | 'unauthorized'
  | 'throttled'
  | 'server-error'
  | 'invalid-response';

const CODES: ReadonlySet<unknown> = new Set<RemoteConfigErrorCode>([
  'timeout',
  'network-error',
  'unauthorized',
  'throttled',
  'server-error',
  'invalid-response',
]);

// `cause` is declared here rather than as a class field: ES2022 adds
// `Error.cause`, so a field would need `override` with lib es2022 and must not
// have it with lib es2020.
export interface RemoteConfigError {
  /** The underlying error, if any. */
  readonly cause?: unknown;
}

/** Error thrown (as a rejection) by `fetch()` and `fetchAndActivate()`. */
export class RemoteConfigError extends Error {
  /** Machine readable error code. */
  readonly code: RemoteConfigErrorCode;
  /** HTTP status code, when the error came from an HTTP response. */
  readonly statusCode?: number;
  /** For `throttled`: when fetching may be retried, in epoch milliseconds. */
  readonly throttleEndTimeMillis?: number;

  constructor(
    code: RemoteConfigErrorCode,
    message: string,
    options: {
      statusCode?: number | undefined;
      throttleEndTimeMillis?: number | undefined;
      cause?: unknown;
    } = {},
  ) {
    super(message);
    // Keeps `instanceof` working when the class is compiled down to ES5.
    Object.setPrototypeOf(this, new.target.prototype);
    this.name = 'RemoteConfigError';
    this.code = code;
    if (options.statusCode !== undefined) this.statusCode = options.statusCode;
    if (options.throttleEndTimeMillis !== undefined) {
      this.throttleEndTimeMillis = options.throttleEndTimeMillis;
    }
    if (options.cause !== undefined) (this as { cause?: unknown }).cause = options.cause;
  }

  /** For example `RemoteConfigError[server-error] (HTTP 502): boom`. */
  override toString(): string {
    const status = this.statusCode === undefined ? '' : ` (HTTP ${this.statusCode})`;
    return `RemoteConfigError[${this.code}]${status}: ${this.message}`;
  }
}

/**
 * Whether `error` is a {@link RemoteConfigError}. Also recognises errors
 * created by another copy of this package.
 */
export function isRemoteConfigError(error: unknown): error is RemoteConfigError {
  if (error instanceof RemoteConfigError) return true;
  return (
    error instanceof Error &&
    error.name === 'RemoteConfigError' &&
    CODES.has((error as { code?: unknown }).code)
  );
}
