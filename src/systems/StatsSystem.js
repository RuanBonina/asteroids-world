import { Storage } from "../config/Storage.js";

export class StatsSystem {
  constructor() {
    this.destroyed = 0;
    this.misses = 0;
    this.clicks = 0;
    this.lastResult = Storage.loadLastResult();
  }

  resetRun() {
    this.destroyed = 0;
    this.misses = 0;
    this.clicks = 0;
  }

  recordDestroyed() {
    this.destroyed += 1;
  }
  recordMiss() {
    this.misses += 1;
  }
  recordClick() {
    this.clicks += 1;
  }

  finalize(timeSec) {
    this.lastResult = {
      destroyed: this.destroyed,
      misses: this.misses,
      clicks: this.clicks,
      timeSec,
    };
    Storage.saveLastResult(this.lastResult);
  }
}
