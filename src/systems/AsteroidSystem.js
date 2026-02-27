import { rand } from "../util/math.js";

export class AsteroidSystem {
  constructor(getSize, getSpeedMul) {
    this.getSize = getSize;
    this.getSpeedMul = getSpeedMul;
    this.asteroid = null;
    this.spawnCooldown = 0;
  }

  clear() {
    this.asteroid = null;
    this.spawnCooldown = 0;
  }
  
  setSpawnCooldown() {
    this.spawnCooldown = rand(0.2, 0.5); 
  }

  ensureOne() {
    if (this.asteroid) return;
    if (this.spawnCooldown > 0) return;
    this.asteroid = this.makeAsteroid();
  }

  makeAsteroid() {
    const { w, h } = this.getSize();
    const centerX = w / 2;
    const centerY = h / 2;

    // mais distante do centro: spread maior
    const spread = Math.min(w, h) * 0.28;
    const targetX = centerX + rand(-spread, spread);
    const targetY = centerY + rand(-spread, spread);

    const side = Math.floor(rand(0, 4));
    let x, y;

    if (side === 0) {
      x = rand(-80, w + 80);
      y = -80;
    } else if (side === 1) {
      x = w + 80;
      y = rand(-80, h + 80);
    } else if (side === 2) {
      x = rand(-80, w + 80);
      y = h + 80;
    } else {
      x = -80;
      y = rand(-80, h + 80);
    }

    const baseSpeed = rand(38, 78);
    const speed = baseSpeed * this.getSpeedMul();

    const dx = targetX - x;
    const dy = targetY - y;
    const len = Math.hypot(dx, dy) || 1;

    const vx = (dx / len) * speed;
    const vy = (dy / len) * speed;

    const r = rand(22, 46);
    const rot = rand(-0.7, 0.7);
    const jag = Math.floor(rand(7, 12));
    const points = [];
    for (let i = 0; i < jag; i++) {
      const a = (i / jag) * Math.PI * 2;
      const rr = r * rand(0.75, 1.15);
      points.push({ a, rr });
    }

    return { x, y, vx, vy, r, rot, ang: rand(0, Math.PI * 2), hp: 1, points };
  }

  update(dt) {
    if (this.spawnCooldown > 0) {
      this.spawnCooldown = Math.max(0, this.spawnCooldown - dt);
    }
    this.ensureOne();
    const a = this.asteroid;
    if (!a) return { missed: false };

    a.x += a.vx * dt;
    a.y += a.vy * dt;
    a.ang += a.rot * dt;

    const { w, h } = this.getSize();
    const pad = 120;
    const missed = a.x < -pad || a.x > w + pad || a.y < -pad || a.y > h + pad;
    if (missed) {
      this.asteroid = null;
      this.setSpawnCooldown();
    }
    return { missed };
  }

  tryHit(p) {
    const a = this.asteroid;
    if (!a) return { hit: false };

    const dx = p.x - a.x;
    const dy = p.y - a.y;

    if (dx * dx + dy * dy <= a.r * a.r) {
      const out = { hit: true, x: a.x, y: a.y, r: a.r };
      this.asteroid = null;
      this.setSpawnCooldown();
      return out;
    }
    return { hit: false };
  }
}
