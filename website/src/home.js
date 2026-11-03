/* The home page: the welcome glides into the header, Voxette's short chat, and the app window to click around in.
   ICON and MINI come from build.py. */
(() => {
  const root = document.documentElement;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => r.querySelectorAll(s);

  /* ---------- The welcome glides into the header ----------
     About two scroll steps down, the big heart and name shrink and travel to the logo spot at the top left
     (half a second), and come back near the top. The header turns to glass as they arrive. */
  (() => {
    const top = $('#top-bar'), brand = $('.brand', top), H = $('#heartbox'), Wd = $('#word'), logo = $('.logo', brand), bt = $('.bt', brand);
    let m = null, raf = 0, p = scrollY > 140 ? 1 : 0, last = 0;
    function measure() {
      H.style.transform = Wd.style.transform = ''; H.style.opacity = Wd.style.opacity = '';
      const y = scrollY, a = H.getBoundingClientRect(), b = Wd.getBoundingClientRect(), la = logo.getBoundingClientRect(), lb = bt.getBoundingClientRect();
      m = { h: { x: a.left, y: a.top + y, w: a.width }, w: { x: b.left, y: b.top + y, w: b.width }, lh: { x: la.left, y: la.top, w: la.width }, lw: { x: lb.left, y: lb.top, w: lb.width } };
      paint();
    }
    const ease = t => t * t * (3 - 2 * t);
    const fly = (el, from, to, k, y) => { el.style.transform = `translate(${(to.x - from.x) * k}px,${(to.y - (from.y - y)) * k}px) scale(${1 + (to.w / from.w - 1) * k})`; };
    function paint(t = performance.now()) {
      raf = 0; if (!m) return;
      const y = scrollY, goal = y > 140 ? 1 : 0, dt = last ? Math.min(50, t - last) : 16; last = t;
      p = reduce ? goal : goal > p ? Math.min(goal, p + dt / 500) : Math.max(goal, p - dt / 500);
      if (p !== goal) raf = requestAnimationFrame(paint); else last = 0;
      const e = ease(p), done = p >= 1;
      top.classList.toggle('solid', p > .85); brand.classList.toggle('on', done);
      if (reduce) { H.style.opacity = Wd.style.opacity = done ? '0' : ''; return; }
      if (done && y > innerHeight * 1.5) return; // long gone under the header
      fly(H, m.h, m.lh, e, y); H.style.opacity = done ? '0' : '1';
      if (m.lw.w > 2) { fly(Wd, m.w, m.lw, e, y); Wd.style.opacity = done ? '0' : '1'; }
      else { Wd.style.transform = `translateY(${-30 * e}px)`; Wd.style.opacity = String(Math.max(0, 1 - e * 1.6)); } // phones hide the name in the header
    }
    addEventListener('scroll', () => { if (!raf) raf = requestAnimationFrame(paint); }, { passive: true });
    addEventListener('resize', () => { last = 0; measure(); });
    (document.fonts?.ready || Promise.resolve()).then(measure); measure();
    // the heart leans toward the pointer on the welcome
    const heartEl = $('#heart');
    if (!reduce) {
      H.addEventListener('pointermove', e => { if (p > 0) return; const r = heartEl.getBoundingClientRect();
        heartEl.style.setProperty('--ry', ((e.clientX - r.left) / r.width - .5) * 14 + 'deg'); heartEl.style.setProperty('--rx', -((e.clientY - r.top) / r.height - .5) * 14 + 'deg'); });
      H.addEventListener('pointerleave', () => { heartEl.style.removeProperty('--rx'); heartEl.style.removeProperty('--ry'); });
    }
  })();


  /* ---------- Questions open and close like liquid: the answer's height eases, its text drifts in ---------- */
  $$('details.qa').forEach(d => {
    const sum = d.querySelector('summary'), body = d.querySelector(':scope > div');
    let anim = null;
    sum.addEventListener('click', e => {
      if (reduce) return; e.preventDefault();
      const opening = !d.open || d.classList.contains('closing');
      const from = d.open ? body.getBoundingClientRect().height : 0; // a closed answer still reports its size
      anim?.cancel();
      if (opening) { d.open = true; d.classList.remove('closing'); }
      else d.classList.add('closing');
      body.style.height = ''; const to = opening ? body.scrollHeight : 0;
      anim = body.animate([{ height: from + 'px', opacity: opening ? Math.min(1, from / 40) : 1, transform: `translateY(${opening ? -6 : 0}px)` },
                           { height: to + 'px', opacity: opening ? 1 : 0, transform: `translateY(${opening ? 0 : -6}px)` }],
        { duration: opening ? 520 : 380, easing: opening ? 'cubic-bezier(.22, 1, .36, 1)' : 'cubic-bezier(.4, 0, .2, 1)' });
      anim.onfinish = () => { anim = null; if (!opening) { d.open = false; d.classList.remove('closing'); } };
    });
  });
})();
