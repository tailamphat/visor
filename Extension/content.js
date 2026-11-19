// Runs in media sites' pages. Reports the page's media to the background
// script whenever it plays, pauses, seeks or changes track, and carries out
// play/pause/next/previous from Visor. Same reading as Visor's AppleScript probe
// (BrowserMedia.probe), so both paths show the same thing.
(() => {
  const api = globalThis.browser ?? chrome;
  let last = '';

  function media() {
    const all = [...document.querySelectorAll('video,audio')];
    return all.find(e => !e.paused) || all.find(e => e.currentTime > 0) || null;
  }

  function state() {
    const m = media();
    if (!m) return null;
    const s = navigator.mediaSession && navigator.mediaSession.metadata;
    const art = s && s.artwork && s.artwork.length ? s.artwork[s.artwork.length - 1].src : '';
    return {
      p: !m.paused, r: m.readyState, t: m.currentTime || 0, d: isFinite(m.duration) ? m.duration : 0,
      title: (s && s.title) || document.title, artist: (s && s.artist) || '', album: (s && s.album) || '',
      art, url: location.href,
    };
  }

  function report() {
    const now = state();
    // Position moves on its own; only report it with something else.
    const key = JSON.stringify(now && { ...now, t: 0 });
    if (key === last) return;
    last = key;
    api.runtime.sendMessage({ type: 'media', state: now }).catch(() => {});
  }

  let soon = 0;
  function reportSoon() {
    clearTimeout(soon);
    soon = setTimeout(report, 250);
  }

  // Media events don't bubble, but they can be caught on the way down.
  for (const name of ['play', 'playing', 'pause', 'ended', 'loadedmetadata', 'durationchange', 'emptied']) {
    document.addEventListener(name, reportSoon, true);
  }
  document.addEventListener('seeked', () => { last = ''; reportSoon(); }, true);
  // A new track usually changes the page title.
  const title = document.querySelector('title');
  if (title) new MutationObserver(reportSoon).observe(title, { childList: true, characterData: true, subtree: true });

  function click(selector) {
    const button = document.querySelector(selector);
    if (button) button.click();
    return !!button;
  }

  api.runtime.onMessage.addListener(message => {
    if (message.type === 'report') { last = ''; report(); return; }
    if (message.type !== 'command') return;
    const m = media() || document.querySelector('video,audio');
    if (message.command === 'playPause') {
      if (m) { if (m.paused) m.play().catch(() => {}); else m.pause(); }
    } else if (message.command === 'next') {
      click(".ytp-next-button, ytmusic-player-bar .next-button, .skipControl__next, [data-testid='control-button-skip-forward'], button[aria-label='Next']");
    } else if (message.command === 'previous') {
      if (!click("ytmusic-player-bar .previous-button, .skipControl__previous, [data-testid='control-button-skip-back'], button[aria-label='Previous']") && m) m.currentTime = 0;
    }
    last = '';
    setTimeout(report, 400);
  });

  window.addEventListener('pagehide', () => api.runtime.sendMessage({ type: 'media', state: null }).catch(() => {}));
  report();
})();
