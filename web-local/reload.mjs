// Independent of app.js so editing a broken application can recover the page.
(() => {
  const valid = value => value && ['styles', 'page'].every(key => /^[a-f0-9]{64}$/.test(value[key]));
  let versions;
  try { versions = JSON.parse(document.querySelector('meta[name="omiloc-assets"]').content); }
  catch { return; }
  if (!valid(versions)) return;
  let timer, request = null, paused = false, generation = 0, reloading = false;

  async function updateStyles(version, signal) {
    const current = document.querySelector('link[rel="stylesheet"]');
    if (!current || signal.aborted) return false;
    const replacement = current.cloneNode();
    replacement.href = `/style.css?v=${version}`;
    return new Promise(resolve => {
      const finish = loaded => {
        replacement.onload = replacement.onerror = null;
        signal.removeEventListener('abort', abort);
        if (loaded) current.remove(); else replacement.remove();
        resolve(loaded);
      };
      const abort = () => finish(false);
      replacement.onload = () => finish(true);
      replacement.onerror = () => finish(false);
      signal.addEventListener('abort', abort, {once: true});
      current.after(replacement);
    });
  }

  async function poll() {
    if (paused || request || reloading) return;
    clearTimeout(timer);
    if (!document.hidden) {
      const controller = new AbortController(), started = generation;
      const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(5000)]);
      request = controller;
      try {
        const response = await fetch('/api/assets', {cache: 'no-store', signal});
        if (!response.ok) throw new Error('Assets unavailable');
        const next = await response.json();
        if (paused || started !== generation || !valid(next)) return;
        if (next.page !== versions.page) {
          // Do not interrupt the visible result of an in-flight deletion.
          if (!document.querySelector('#delete-confirm:disabled')) {
            reloading = true;
            location.reload();
          }
        } else if (next.styles !== versions.styles && await updateStyles(next.styles, signal)) {
          versions = next;
        }
      } catch {
        // A save or library restart can briefly make assets unavailable. Retry.
      } finally {
        request = null;
        if (!paused && !reloading) timer = setTimeout(poll, 1000);
      }
    } else {
      timer = setTimeout(poll, 1000);
    }
  }

  addEventListener('pagehide', () => {
    paused = true;
    generation++;
    clearTimeout(timer);
    request?.abort();
  });
  addEventListener('pageshow', () => {
    if (!paused) return;
    paused = false;
    poll();
  });
  poll();
})();
