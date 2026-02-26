export class RunClock {
  constructor() {
    this.running = false;
    this.paused = false;
    this.startTimeMs = 0;
    this.pausedAtMs = 0;
    this.pausedTotalMs = 0;
  }

  start(now) {
    this.running = true;
    this.paused = false;
    this.startTimeMs = now;
    this.pausedAtMs = 0;
    this.pausedTotalMs = 0;
  }

  stop() {
    this.running = false;
    this.paused = false;
  }

  togglePause(now) {
    if (!this.running) return;
    this.paused = !this.paused;
    if (this.paused) this.pausedAtMs = now;
    else {
      this.pausedTotalMs += (now - this.pausedAtMs);
      this.pausedAtMs = 0;
    }
  }

  elapsedSeconds(now) {
    if (!this.running) return 0;
    const effectiveNow = this.paused ? this.pausedAtMs : now;
    const elapsedMs = effectiveNow - this.startTimeMs - this.pausedTotalMs;
    return Math.max(0, elapsedMs / 1000);
  }
}