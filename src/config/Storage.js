export const Storage = {
  keys: {
    settings: "aster_click_settings_v1",
    last: "aster_click_last_v1",
  },

  loadSettings() {
    try { return JSON.parse(localStorage.getItem(this.keys.settings) || "null"); }
    catch { return null; }
  },

  saveSettings(s) {
    try { localStorage.setItem(this.keys.settings, JSON.stringify(s)); } catch {}
  },

  loadLastResult() {
    try { return JSON.parse(localStorage.getItem(this.keys.last) || "null"); }
    catch { return null; }
  },

  saveLastResult(r) {
    try { localStorage.setItem(this.keys.last, JSON.stringify(r)); } catch {}
  },
};