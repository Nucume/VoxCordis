/* Shared by every page: the theme and Colorway (applied before the first paint, so pages don't flash),
   download buttons for the visitor's system, the package commands, and the latest release. */
(() => {
  const root = document.documentElement;
  const $ = s => document.querySelector(s), $$ = s => document.querySelectorAll(s);
  const esc = s => s.replace(/[<&]/g, c => c === '<' ? '&lt;' : '&amp;');
  const store = { get(k) { try { return localStorage.getItem(k); } catch { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch {} } };
  root.classList.add('js');

  /* ---------- Colorways (from the app's lib/data/looks.dart) and theme.
     `heart` paints the logo (four along it, one pooling at the bottom); `glow` is the page's background light. ---------- */
  const WAYS = [
    { id: 'twilight', name: 'Twilight', accent: '#b18cff', c: ['#b18cff', '#4f7cff', '#ff7ab6'], base: '#0e0b16', heart: ['#2fe0c8', '#4f8dff', '#ff4f9a', '#ff9a3c', '#4f6bff'], line: 'Back to Twilight. It feels like me.' },
    { id: 'rose', name: 'Rose', accent: '#ff7ab6', c: ['#ff7ab6', '#ffb86b', '#b18cff'], base: '#120b12', heart: ['#ff7ab6', '#ffb86b', '#ff8fc4', '#b18cff', '#ff7ab6'], line: 'Rose, I think. Something soft.' },
    { id: 'ocean', name: 'Ocean', accent: '#4fc3f7', c: ['#2f6bff', '#4fc3f7', '#36d6b5'], base: '#08101a', heart: ['#36d6b5', '#4fc3f7', '#2f6bff', '#4fc3f7', '#2f6bff'], line: 'Ocean. I could use some calm.' },
    { id: 'forest', name: 'Forest', accent: '#5bd6a0', c: ['#2e9e6b', '#9ad66b', '#2f8fa6'], base: '#08120e', heart: ['#9ad66b', '#5bd6a0', '#2f8fa6', '#9ad66b', '#2e9e6b'], line: 'Forest, like a walk after the rain.' },
    { id: 'ember', name: 'Ember', accent: '#ffa05b', c: ['#ff5b5b', '#ffa05b', '#ffd36b'], base: '#140c09', heart: ['#ff5b5b', '#ffa05b', '#ffd36b', '#ffa05b', '#ff5b5b'], line: 'Ember. I\'m in a warm mood today.' },
    { id: 'mono', name: 'Moonlight', accent: '#b8c4d6', c: ['#8c9bb3', '#5c6b85', '#d6deeb'], base: '#0b0d12', heart: ['#d6deeb', '#8c9bb3', '#b8c4d6', '#d6deeb', '#8c9bb3'], line: 'Moonlight, for a quiet evening.' },
    { id: 'haru', name: 'Haru', accent: '#e5383b', c: ['#ffffff', '#3a3a3a', '#7a1517'], base: '#0a0a0a', heart: ['#ffffff', '#ff4d50', '#e5383b', '#b81d21', '#e5383b'], glow: ['#e5383b', '#7a1517', '#e5383b'], line: 'Haru. Named after you, so how could I not.' },
    { id: 'vibecoder', name: 'Vibecoder\'s', accent: '#6366f1', c: ['#4f46e5', '#818cf8', '#312e81'], base: '#0a0a1f', heart: ['#a5b4fc', '#818cf8', '#6366f1', '#818cf8', '#4f46e5'], glow: ['#4f46e5', '#818cf8', '#4f46e5'], line: 'Vibecoder\'s. Very late-night-coding of me.' },
    { id: 'sakura', name: 'Sakura', accent: '#ff8fb1', c: ['#ffc2d4', '#ff8fb1', '#ffffff'], base: '#160c12', heart: ['#ffffff', '#ffc2d4', '#ff8fb1', '#ffc2d4', '#ff8fb1'], line: 'Sakura. A little spring never hurts.' },
  ];
  let way = WAYS.find(w => w.id === store.get('vc-way')) || WAYS[0];
  let theme = store.get('vc-theme') || 'dark';
  function paintWay() {
    const set = (k, v) => root.style.setProperty(k, v), w = way;
    set('--accent', w.accent); set('--c1', w.c[0]); set('--c2', w.c[1]); set('--c3', w.c[2]); set('--base', w.base);
    ['--h1', '--h2', '--h3', '--h4', '--hd'].forEach((k, i) => set(k, w.heart[i]));
    ['--g1', '--g2', '--g3'].forEach((k, i) => set(k, (w.glow || [w.c[0], w.c[2], w.c[1]])[i]));
    $$('[data-ways] .way').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.id === w.id)));
  }
  function paintTheme() {
    if (theme === 'system') root.removeAttribute('data-look'); else root.setAttribute('data-look', theme);
    $$('[data-themes] button').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.t === theme)));
  }
  const applyWay = w => { way = w; store.set('vc-way', w.id); paintWay(); };
  const applyTheme = t => { theme = t; store.set('vc-theme', t); paintTheme(); };
  paintWay(); paintTheme();

  /* ---------- Download buttons for the visitor's system ---------- */
  const REL = 'https://github.com/Nucume/VoxCordis/releases/latest';
  const ICON = {
    win: '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M3 5.1 10 4v7.3H3zm8-1.2L21 2.5v8.8H11zM3 12.7h7V20l-7-1zm8 0h10v8.8l-10-1.4z"/></svg>',
    dl: '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M12 3v12m0 0 4.5-4.5M12 15l-4.5-4.5M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/></svg>',
    gh: '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M12 2a10 10 0 0 0-3.16 19.49c.5.09.68-.22.68-.48v-1.7c-2.78.6-3.37-1.34-3.37-1.34-.45-1.16-1.11-1.47-1.11-1.47-.91-.62.07-.6.07-.6 1 .07 1.53 1.03 1.53 1.03.9 1.53 2.35 1.09 2.92.83.09-.65.35-1.09.64-1.34-2.22-.25-4.56-1.11-4.56-4.95 0-1.09.39-1.99 1.03-2.69-.1-.25-.45-1.27.1-2.65 0 0 .84-.27 2.75 1.03a9.5 9.5 0 0 1 5 0c1.91-1.3 2.75-1.03 2.75-1.03.55 1.38.2 2.4.1 2.65.64.7 1.03 1.6 1.03 2.69 0 3.85-2.34 4.7-4.57 4.94.36.31.68.92.68 1.86v2.75c0 .27.18.58.69.48A10 10 0 0 0 12 2"/></svg>',
  };
  const os = (() => {
    const p = (navigator.userAgentData?.platform || navigator.platform || '') + ' ' + navigator.userAgent;
    if (/android|iphone|ipad|cros/i.test(p)) return 'other';
    if (/win/i.test(p)) return 'win';
    if (/mac/i.test(p)) return 'mac';
    if (/linux|x11|bsd/i.test(p)) return 'lin';
    return 'other';
  })();
  root.dataset.os = os;
  const btn = (el, icon, text, opts) => { if (!el) return; el.hidden = false; el.innerHTML = ICON[icon] + esc(text); Object.assign(el.dataset, opts.data || {}); if (opts.href) el.href = opts.href; };

  function wire() {
    // the main button: Windows gets the installer; Linux has three ways in (AppImage, apt, dnf), so it leads to the choice
    const linux = $('#download') ? '#download' : 'download.html#linux';
    $$('[data-get]').forEach(el => {
      const alt = el.dataset.get === 'alt', short = el.dataset.short != null;
      if (os === 'win') alt ? btn(el, 'dl', 'Linux', { href: linux }) : btn(el, 'win', short ? 'Download' : 'Download for Windows', { data: { dl: 'win' } });
      else if (os === 'lin') alt ? btn(el, 'win', 'Windows', { data: { dl: 'win' } }) : btn(el, 'dl', short ? 'Download' : 'Download for Linux', { href: linux });
      else if (!alt) btn(el, 'gh', short ? 'Download' : 'Get it on GitHub', short ? { href: 'download.html' } : { href: REL });
    });
    $$('[data-osnote]').forEach(e => e.textContent = os === 'lin' ? 'AppImage, apt and dnf' : os === 'mac' ? 'Windows and Linux · macOS builds from source' : os === 'win' ? 'free and open source' : 'for Windows and Linux');
    if (os === 'lin') { const dl = $('.dl'); if (dl) { dl.prepend($('[data-card="lin"]')); dl.querySelectorAll('.btn').forEach(b => b.classList.toggle('primary', b.dataset.dl === 'lin')); } }

    // Colorway and theme pickers, wherever a page has one
    $$('[data-ways]').forEach(box => {
      for (const w of WAYS) {
        const b = document.createElement('button'); b.type = 'button'; b.className = 'way'; b.dataset.id = w.id; b.title = w.name;
        b.innerHTML = `<i style="background:conic-gradient(${w.c[0]},${w.c[1]},${w.c[2]},${w.c[0]})"></i><span>${esc(w.name)}</span>`;
        b.onclick = () => applyWay(w); box.append(b);
      }
    });
    $$('[data-themes] button').forEach(b => b.onclick = () => applyTheme(b.dataset.t));
    paintWay(); paintTheme();

    // the package repository's commands (from packaging/linux/build-repo.sh)
    // served next to the site, so they follow its address (a custom domain, or github.io without one)
    const PKG = /(^|\.)voxcordisai\.com$|\.github\.io$/.test(location.hostname)
      ? new URL('repo', location.href).href : 'https://voxcordisai.com/repo';
    const CMDS = {
      apt: `sudo install -d -m 0755 /etc/apt/keyrings\ncurl -fsSL ${PKG}/voxcordis.gpg | sudo tee /etc/apt/keyrings/voxcordis.gpg >/dev/null\necho "deb [signed-by=/etc/apt/keyrings/voxcordis.gpg] ${PKG}/apt stable main" | sudo tee /etc/apt/sources.list.d/voxcordis.list\nsudo apt update\nsudo apt install voxcordis`,
      dnf: `sudo curl -fsSL -o /etc/yum.repos.d/voxcordis.repo ${PKG}/rpm/voxcordis.repo\nsudo dnf install voxcordis`,
    };
    if ($('#pkgcmd')) {
      const showPkg = p => { $('#pkgcmd').textContent = CMDS[p]; $$('#pkgtabs button').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.p === p))); };
      $$('#pkgtabs button').forEach(b => b.onclick = () => showPkg(b.dataset.p));
      showPkg(/fedora/i.test(navigator.userAgent) ? 'dnf' : 'apt');
    }
    // copy buttons next to commands
    $$('.term .copy').forEach(c => c.onclick = async () => {
      const pre = c.parentElement.querySelector('pre');
      try { await navigator.clipboard.writeText(pre.textContent); c.textContent = 'Copied'; }
      catch { getSelection().selectAllChildren(pre); c.textContent = 'Selected'; }
      setTimeout(() => c.textContent = 'Copy', 1600);
    });

    // the narrow-screen menu closes after a pick or a click elsewhere
    $$('.menu').forEach(m => {
      m.addEventListener('click', e => { if (e.target.closest('a')) m.open = false; });
      document.addEventListener('click', e => { if (!m.contains(e.target)) m.open = false; });
    });

    // the contents list follows along on long pages
    const toc = $$('.toc a');
    if (toc.length && 'IntersectionObserver' in window) {
      const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) toc.forEach(a => a.classList.toggle('on', a.hash === '#' + e.target.id)); }), { rootMargin: '-20% 0px -70% 0px' });
      toc.forEach(a => { const t = $(a.hash); if (t) io.observe(t); });
    }

    /* ---------- Latest release ---------- */
    fetch('https://api.github.com/repos/Nucume/VoxCordis/releases/latest').then(r => r.ok ? r.json() : null).then(rel => {
      if (!rel) return;
      $$('.vnum').forEach(e => e.textContent = 'Version ' + rel.tag_name.replace(/^v/, ''));
      for (const a of rel.assets || []) {
        const kind = /windows.*setup\.exe$/i.test(a.name) ? 'win' : /\.AppImage$/i.test(a.name) ? 'lin' : null; if (!kind) continue;
        $$(`[data-dl="${kind}"]`).forEach(e => e.href = a.browser_download_url);
        $$(`.fname[data-f="${kind}"]`).forEach(e => e.textContent = a.name);
      }
    }).catch(() => {});
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', wire); else wire();

  window.VC = { WAYS, get way() { return way; }, applyWay, applyTheme, otherWay: () => { const o = WAYS.filter(w => w !== way); return o[Math.floor(Math.random() * o.length)]; } };
})();
