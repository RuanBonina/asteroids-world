export const Fullscreen = {
  is() { return !!document.fullscreenElement; },

  async toggle() {
    try {
      if (!this.is()) await document.documentElement.requestFullscreen();
      else await document.exitFullscreen();
    } catch {}
  },

  iconHTML() {
    return this.is()
      ? `<svg viewBox="0 0 24 24" fill="none" aria-hidden="true">
           <path d="M9 9H5V5M15 9h4V5M9 15H5v4M15 15h4v4"
                 stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
         </svg>`
      : `<svg viewBox="0 0 24 24" fill="none" aria-hidden="true">
           <path d="M9 5H5v4M15 5h4v4M9 19H5v-4M15 19h4v-4"
                 stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
         </svg>`;
  },
};