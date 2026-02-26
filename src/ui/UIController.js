import { clamp } from "../util/math.js";
import { fmtTime } from "../util/format.js";

export class UIController {
  constructor(els, settings, stats) {
    this.els = els;
    this.settings = settings;
    this.stats = stats;
    this.draft = {
      uiOpacity: this.settings.value.uiOpacity,
      speedLevel: this.settings.value.asteroidSpeedLevel,
      difficultyProgression: this.settings.value.difficultyProgression,
    };

    this.refreshLastResult();
  }

  showStart() {
    this.els.startScreen.style.display = "grid";
    this.els.quitBtn.style.display = "none";
    this.els.pauseBtn.style.display = "none";
  }

  hideStart() {
    this.els.startScreen.style.display = "none";
    this.els.quitBtn.style.display = "grid";
    this.els.pauseBtn.style.display = "grid";
  }

  refreshLastResult() {
    const r = this.stats.lastResult;
    if (!r) {
      this.els.lastBox.textContent = "Última partida: (ainda não jogada)";
      return;
    }

    const clicks = r.clicks ?? 0;
    const destroyed = r.destroyed ?? 0;
    const acc = clicks > 0 ? Math.round((destroyed / clicks) * 100) : 0;

    this.els.lastBox.textContent =
      `Última partida\n` +
      `Destruídos: ${destroyed}\n` +
      `Fugas: ${r.misses}\n` +
      `Cliques: ${clicks}\n` +
      `Precisão: ${acc}%\n` +
      `Tempo: ${fmtTime(r.timeSec)}`;
  }

  syncFromSettings() {
    const op = clamp(
      Math.round((this.settings.value.uiOpacity * 100) / 10) * 10,
      10,
      100,
    );
    this.els.opacityRange.value = String(op);
    this.els.opacityOut.textContent = `${op}%`;

    const lvl = Math.round(this.settings.value.asteroidSpeedLevel);
    this.els.speedRange.value = String(lvl);
    this.els.speedOut.textContent = `Nível ${lvl}`;

    const on = !!this.settings.value.difficultyProgression;
    this.els.difficultyToggle.checked = on;
    this.els.difficultyOut.textContent = on ? "Ativa" : "Desligada";
  }

  beginDraftFromSettings() {
    this.draft.uiOpacity = this.settings.value.uiOpacity;
    this.draft.speedLevel = this.settings.value.asteroidSpeedLevel;

    // reflete no modal
    const op = clamp(
      Math.round((this.settings.value.uiOpacity * 100) / 10) * 10,
      10,
      100,
    );
    this.els.opacityRange.value = String(op);
    this.els.opacityOut.textContent = `${op}%`;

    const lvl = Math.round(this.draft.speedLevel);
    this.els.speedRange.value = String(lvl);
    this.els.speedOut.textContent = `Nível ${lvl}`;

    const on = !!this.draft.difficultyProgression;
    this.els.difficultyToggle.checked = on;
    this.els.difficultyOut.textContent = on ? "Ativa" : "Desligada";
  }

  updateDraftDifficultyFromUI() {
    const on = !!this.els.difficultyToggle.checked;
    this.draft.difficultyProgression = on;
    this.els.difficultyOut.textContent = on ? "Ativa" : "Desligada";
  }

  updateDraftOpacityFromUI() {
    const raw = Number(this.els.opacityRange.value); // 10..100, step 10
    const v01 = clamp(raw / 100, 0.1, 1);
    this.draft.uiOpacity = v01;
    this.els.opacityOut.textContent = `${raw}%`;
  }

  updateDraftSpeedFromUI() {
    const lvl = clamp(Number(this.els.speedRange.value), 1, 5);
    this.draft.speedLevel = lvl;
    this.els.speedOut.textContent = `Nível ${lvl}`;
  }

  applyDraft() {
    this.settings.set({
      uiOpacity: this.draft.uiOpacity,
      asteroidSpeedLevel: this.draft.speedLevel,
      difficultyProgression: this.draft.difficultyProgression,
    });

    // mantém UI consistente
    this.syncFromSettings();
  }
}
