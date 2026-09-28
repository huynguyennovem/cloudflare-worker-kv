/** A controllable epoch-millisecond clock. */
export class FakeClock {
  now: number;

  constructor(start: number = Date.UTC(2026, 0, 1)) {
    this.now = start;
  }

  /** Pass as the `now` option. */
  readonly call = (): number => this.now;

  advance(millis: number): void {
    this.now += millis;
  }
}
