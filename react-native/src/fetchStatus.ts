/**
 * Outcome of the most recent fetch attempt, as reported by
 * `CloudflareRemoteConfig.lastFetchStatus`.
 *
 * - `no_fetch_yet`: no fetch has been attempted yet.
 * - `success`: the last fetch succeeded (including "not modified").
 * - `failure`: the last fetch failed (network error, timeout, bad response...).
 * - `throttled`: the last fetch was rejected because of rate limiting.
 */
export type FetchStatus = 'no_fetch_yet' | 'success' | 'failure' | 'throttled';

/** The {@link FetchStatus} values, named like `@react-native-firebase/remote-config`. */
export const LastFetchStatus: {
  readonly SUCCESS: 'success';
  readonly FAILURE: 'failure';
  readonly NO_FETCH_YET: 'no_fetch_yet';
  readonly THROTTLED: 'throttled';
} = /* @__PURE__ */ Object.freeze({
  SUCCESS: 'success',
  FAILURE: 'failure',
  NO_FETCH_YET: 'no_fetch_yet',
  THROTTLED: 'throttled',
});

// The cache stores the names used by the Flutter reference implementation.
const STORED_NAMES: ReadonlyMap<FetchStatus, string> = new Map<FetchStatus, string>([
  ['no_fetch_yet', 'noFetchYet'],
  ['success', 'success'],
  ['failure', 'failure'],
  ['throttled', 'throttle'],
]);

const FROM_STORED_NAMES: ReadonlyMap<unknown, FetchStatus> = new Map<unknown, FetchStatus>(
  Array.from(STORED_NAMES, ([status, stored]) => [stored, status]),
);

/** The name persisted for `status` (`noFetchYet`, `success`, `failure`, `throttle`). */
export function fetchStatusToStored(status: FetchStatus): string {
  return STORED_NAMES.get(status) ?? 'noFetchYet';
}

/** Parses a persisted status name. Unknown values give `no_fetch_yet`. */
export function fetchStatusFromStored(stored: unknown): FetchStatus {
  return FROM_STORED_NAMES.get(stored) ?? 'no_fetch_yet';
}
