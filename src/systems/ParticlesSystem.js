import { rand, clamp } from "../util/math.js";

export class ParticlesSystem {
  constructor() {
    this.particles = [];
    this.rings = []; 
  }

  clear() {
    this.particles.length = 0;
    this.rings.length = 0; 
  }

  explode(x, y, power) {
    const count = Math.floor(clamp(power * 1.0, 12, 30));
    for (let i = 0; i < count; i++) {
      const a = rand(0, Math.PI * 2);
      const sp = rand(50, 220) * (0.6 + power * 0.02);
      this.particles.push({
        x,
        y,
        vx: Math.cos(a) * sp,
        vy: Math.sin(a) * sp,
        life: rand(0.25, 0.7),
        t: 0,
        size: rand(1, 3),
      });
    }
  }

  ping(x, y) {
    this.rings.push({
      x,
      y,
      t: 0,
      life: 0.35,
      r0: 6,
      r1: 28,
    });
  }

  update(dt) {
    for (let i = this.particles.length - 1; i >= 0; i--) {
      const p = this.particles[i];
      p.t += dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.vx *= Math.pow(0.92, dt * 60);
      p.vy *= Math.pow(0.92, dt * 60);
      if (p.t >= p.life) this.particles.splice(i, 1);
    }

    for (let i = this.rings.length - 1; i >= 0; i--) {
      const r = this.rings[i];
      r.t += dt;
      if (r.t >= r.life) this.rings.splice(i, 1);
    }
  }
}
