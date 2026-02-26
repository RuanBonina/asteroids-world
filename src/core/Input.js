export class Input {
  constructor() {
    this.resetFrame();
    window.addEventListener("keydown", (e) => this.onKeyDown(e));
  }

  attachCanvas(canvas) {
    canvas.addEventListener("click", (e) => this.onClick(canvas, e));
  }

  resetFrame() {
    this.click = null;       // {x,y}
    this.togglePause = false;
    this.quit = false;
  }

  onKeyDown(e) {
    if (e.key === "Escape") this.togglePause = true;
    if (e.key === "x" || e.key === "X") this.quit = true;
  }

  onClick(canvas, ev) {
    const rect = canvas.getBoundingClientRect();
    this.click = { x: ev.clientX - rect.left, y: ev.clientY - rect.top };
  }
}