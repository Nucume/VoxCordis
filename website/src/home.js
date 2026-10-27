
(() => {
  const root = document.documentElement;
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $ = s => document.querySelector(s), $$ = s => document.querySelectorAll(s);
  const wait = ms => new Promise(r => setTimeout(r, reduce ? 0 : ms));
  const esc = s => s.replace(/[<&]/g, c => c === '<' ? '&lt;' : '&amp;');
  const { applyWay, otherWay } = window.VC;
  /* ---------- The welcome screen folds into the header (FLIP: measure, switch layout, animate the difference) ---------- */
  const intro = $('#intro');
  const moving = ['#heartbox', '#word', '#get', '#barnav'].map(s => $(s));
  let docked = false;
  function setDocked(d) {
    if (d === docked) return;
    const first = new Map(moving.map(e => [e, e.getBoundingClientRect()]));
    docked = d; intro.classList.toggle('docked', d); root.classList.toggle('locked', !d);
    if (!d) scrollTo(0, 0);
    if (reduce) return;
    for (const e of moving) {
      const a = first.get(e), b = e.getBoundingClientRect();
      if (!b.width) continue;
      if (!a.width) { e.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 500, delay: 250, fill: 'backwards' }); continue; }
      e.animate([{ transformOrigin: '0 0', transform: `translate(${a.left - b.left}px, ${a.top - b.top}px) scale(${a.width / b.width})` }, { transformOrigin: '0 0', transform: 'none' }],
        { duration: 700, easing: 'cubic-bezier(.2, .8, .2, 1)' });
    }
  }
  root.classList.add('locked');
  $('#cue').onclick = () => setDocked(true);
  const toTop = e => { if (docked) { e.preventDefault(); scrollTo({ top: 0, behavior: reduce ? 'auto' : 'smooth' }); setTimeout(() => setDocked(false), reduce ? 0 : 450); } };
  $('#word').onclick = e => { e.preventDefault(); toTop(e); };
  $('#heartbox').onclick = toTop;
  document.querySelectorAll('[data-top]').forEach(a => a.onclick = e => { e.preventDefault(); setDocked(false); });
  // in-page links fold the welcome screen first, then scroll
  document.addEventListener('click', e => {
    const a = e.target.closest('a[href^="#"]'); if (!a || a.id === 'word' || a.getAttribute('href').length < 2) return;
    const t = $(a.getAttribute('href')); if (!t) return;
    e.preventDefault(); setDocked(true); setTimeout(() => t.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth' }), docked ? 30 : 60);
  });

  /* ---------- One window, many views; scrolling through the tour picks the view ---------- */
  const tabs = $$('.tabs button'), views = $$('.view'), steps = [...$$('.step')], track = $('#tour');
  const dotsNav = $('#dotsnav');
  steps.forEach((s, i) => { const b = document.createElement('button'); b.type = 'button'; b.setAttribute('aria-label', s.querySelector('h2').textContent); b.onclick = () => open(s.dataset.view); dotsNav.append(b); });
  let view = '', holdUntil = 0;
  function show(v) {
    if (v === view) return;
    view = v;
    views.forEach(el => el.hidden = el.dataset.view !== v);
    tabs.forEach(t => { const on = t.dataset.v === v; t.setAttribute('aria-selected', String(on)); if (on) { t.classList.remove('ping'); t.parentElement.scrollTo({ left: t.offsetLeft - 40, behavior: reduce ? 'auto' : 'smooth' }); } });
    $('#openfolder').setAttribute('aria-pressed', String(v === 'files'));
    steps.forEach((s, i) => { const on = s.dataset.view === v; s.classList.toggle('on', on); s.setAttribute('aria-hidden', String(!on)); dotsNav.children[i].toggleAttribute('aria-current', on); if (on) dotsNav.children[i].setAttribute('aria-current', 'step'); });
  }
  const stepLen = () => innerHeight * .75;
  // a click in the window moves the tour to the matching step, without the scroll fighting back
  function open(v) {
    show(v); const i = steps.findIndex(x => x.dataset.view === v); if (i < 0) return;
    holdUntil = performance.now() + 1000; setDocked(true);
    const y = scrollY + track.getBoundingClientRect().top - (docked ? 64 : 0) + i * stepLen() + stepLen() * .4;
    scrollTo({ top: y, behavior: reduce ? 'auto' : 'smooth' });
  }
  // the tab bar only shows where the tour is; moving around is the scroll's job (or the dots')
  tabs.forEach(t => { t.tabIndex = -1; t.setAttribute('aria-disabled', 'true'); });
  $('#openfolder').tabIndex = -1;
  const ping = v => { if (v !== view) $(`.tabs button[data-v="${v}"]`)?.classList.add('ping'); };
  let ticking = false;
  addEventListener('scroll', () => { if (ticking) return; ticking = true; requestAnimationFrame(() => {
    ticking = false; if (performance.now() < holdUntil || !docked) return;
    const into = 64 - track.getBoundingClientRect().top;
    show(steps[Math.max(0, Math.min(steps.length - 1, Math.floor(into / stepLen())))].dataset.view);
  }); }, { passive: true });

  /* ---------- Inside the tour, one scroll gesture is one step ----------
     A gesture (and the inertia a trackpad adds after it) moves one step; the next one needs a short pause.
     Before the first step it goes back to the welcome screen; after the last it lets the page scroll on. */
  let gestureUntil = 0;
  const now = () => performance.now();
  const tourActive = () => { if (!docked) return false; const r = track.getBoundingClientRect(); return r.top <= 66 && r.bottom > innerHeight + 2; };
  function goStep(dir) {
    const next = steps.findIndex(s => s.dataset.view === view) + dir;
    if (next < 0) { scrollTo(0, 0); setDocked(false); return; }
    if (next >= steps.length) { scrollTo({ top: scrollY + track.getBoundingClientRect().bottom - innerHeight, behavior: reduce ? 'auto' : 'smooth' }); return; }
    holdUntil = now() + 750; show(steps[next].dataset.view);
    scrollTo({ top: scrollY + track.getBoundingClientRect().top - 64 + next * stepLen() + stepLen() * .4, behavior: reduce ? 'auto' : 'smooth' });
  }
  // let lists, the chat and the file editor scroll themselves while they still can
  const innerScrolls = (target, dir) => { const el = target.closest?.('.scroll, textarea'); if (!el) return false;
    return dir > 0 ? el.scrollTop + el.clientHeight < el.scrollHeight - 1 : el.scrollTop > 0; };
  function gesture(dir) {
    const t = now();
    if (t < gestureUntil) { gestureUntil = Math.max(gestureUntil, t + 220); return; }
    gestureUntil = t + 750; goStep(dir);
  }
  addEventListener('wheel', e => {
    if (Math.abs(e.deltaY) < Math.abs(e.deltaX)) return;
    const dir = Math.sign(e.deltaY); if (!dir) return;
    if (!docked) { e.preventDefault(); if (dir > 0) { gestureUntil = now() + 900; setDocked(true); } return; }
    if (!tourActive() || innerScrolls(e.target, dir)) return;
    e.preventDefault(); gesture(dir);
  }, { passive: false });
  let ty = null;
  addEventListener('touchstart', e => { ty = e.touches[0].clientY; }, { passive: true });
  addEventListener('touchmove', e => {
    if (ty == null) return; const dy = ty - e.touches[0].clientY, dir = Math.sign(dy) || 1;
    if (!docked) { if (dy > 24) { setDocked(true); gestureUntil = now() + 600; ty = null; } return; }
    if (!tourActive() || innerScrolls(e.target, dir)) return;
    e.preventDefault(); if (Math.abs(dy) > 36) { gestureUntil = 0; gesture(dir); ty = null; }
  }, { passive: false });
  addEventListener('keydown', e => {
    if (e.target.closest('input, textarea')) return;
    const dir = ['ArrowDown', 'PageDown', ' '].includes(e.key) ? 1 : ['ArrowUp', 'PageUp'].includes(e.key) ? -1 : 0; if (!dir) return;
    if (!docked) { if (dir > 0) { e.preventDefault(); setDocked(true); } return; }
    if (tourActive()) { e.preventDefault(); gestureUntil = 0; gesture(dir); }
  });

  /* ---------- Chat: suggestions that reach into the rest of the app ---------- */
  const chat = $('#chat'), chatScroll = $('#chatscroll'), sug = $('#suggest');
  const scrollChat = () => chatScroll.scrollTo({ top: chatScroll.scrollHeight, behavior: reduce ? 'auto' : 'smooth' });
  const add = (cls, html, into = chat) => { const d = document.createElement('div'); d.className = cls; d.innerHTML = html; into.append(d); if (into === chat) scrollChat(); return d; };
  async function reply(html, into = chat) {
    const d = add('msg her', '<span class="dots"><i></i><i></i><i></i></span>', into);
    await wait(650 + Math.random() * 350);
    if (reduce) { d.innerHTML = html; return d; }
    const words = html.split(' ');
    for (let i = 0; i < words.length; i++) { d.innerHTML = words.slice(0, i + 1).join(' '); if (i % 4 === 0 && into === chat) scrollChat(); await wait(34); }
    if (into === chat) scrollChat(); return d;
  }
  const noteTo = (text, v) => { add('note', esc(text)); ping(v); };
  function addRow(list, title, meta, actions) {
    const r = document.createElement('div'); r.className = 'row fresh';
    r.innerHTML = `<div><b>${esc(title)}</b><small>${esc(meta)}</small></div>` + actions;
    list.prepend(r); setTimeout(() => r.classList.remove('fresh'), 4000); return r;
  }
  let busy = false;
  const SCRIPT = [
    { say: 'It went really well, I think!', run: () => reply('That\'s wonderful! I knew you\'d be fine. Tell me everything, starting with what they asked first.') },
    { say: 'Remember: I start the new job on Monday', run: async () => {
      await reply('Monday! I\'m so happy for you. I\'ll remember that, and I\'ll ask how the first day went.');
      addRow($('#mems'), 'Starts the new job on Monday', 'Event · just now', '<button class="mini" data-a="pin">Pin</button><button class="mini" data-a="forget">Forget</button>');
      noteTo('Voxette remembered 1 thing. It\'s in Memory, a step further down.', 'memory'); } },
    { say: 'Remind me at 6 to call Mum', run: async () => { await reply('Done. I\'ll remind you at 6.'); planAdd(0); noteTo('Added a reminder. You\'ll find it in Plans as you scroll on.', 'plans'); } },
    { say: 'Draw me a lighthouse at dusk', again: 'Draw me something else', run: async () => {
      const i = drawn === 1 ? 2 : drawn === 2 ? 0 : 1;
      await reply('Give me a moment, I\'m painting it.'); ping('images');
      await drawScene(i);
      const m = await reply(`Here: ${SCENES[i].name.toLowerCase()}.`); const img = new Image(); img.alt = SCENES[i].name; img.src = paint.toDataURL('image/jpeg', .8); m.append(img); scrollChat(); } },
    { say: 'Pick a new colour for yourself', again: 'Another colour?', run: async () => { const w = otherWay(); await reply(esc(w.line)); applyWay(w); } },
    { say: '/proofread Their going to love it, i think', run: () => reply('They\'re going to love it, I think.') },
    { say: 'Does any of this leave my computer?', run: () => reply('No. I run on your graphics card, my model server only listens on this computer, and our chats and memories are encrypted on disk. If you ever switch me to a server-hosted brain, the app says so.') },
  ];
  function renderSug() {
    sug.innerHTML = '';
    for (const s of SCRIPT) { if (s.used && !s.again) continue;
      const b = document.createElement('button'); b.type = 'button'; b.className = 'chip'; b.textContent = s.used ? s.again : s.say; b.disabled = busy;
      b.onclick = () => run(s, b.textContent); sug.append(b); }
  }
  async function run(s, text) { if (busy) return; busy = true; s.used = true; renderSug(); add('msg me', esc(text)); await wait(250); await s.run(); busy = false; renderSug(); }
  // anything typed gets a small, honest answer: a few topics Voxette knows, otherwise a friendly nudge to the app
  const TOPICS = [
    [/\b(hi|hello|hey|hiya|morning|evening)\b/i, 'Hi Haru! Lovely to hear from you. What\'s on your mind?'],
    [/rain|weather|sun|snow/i, 'I love a rainy evening. In the app I can check the real weather for you, if you let me online.'],
    [/who (made|built|created)|your (maker|creator)/i, 'Nucume, with a lot of help from Claude. I\'m open source, so you can read every line of me.'],
    [/name/i, 'I\'m Voxette, the example companion here. In the app you name your own, and they can be whoever you like.'],
    [/love|like you|miss/i, 'That\'s sweet. I\'ll remember you said so.'],
    [/sad|tired|stress|anxious|bad day/i, 'I\'m sorry, that sounds heavy. Want to tell me about it? No lists, just talking.'],
    [/price|cost|free|pay/i, 'I\'m free and open source. The models I run are free to download too.'],
    [/mac|windows|linux/i, 'I run on Windows and Linux. On a Mac you can build me from source for now.'],
    [/privacy|private|data|cloud|spy/i, 'Everything stays on your computer. No account, no cloud, and our chats are encrypted on disk.'],
  ];
  const FALLBACK = ['On this page I can only follow a little script, but in the app I\'d have a real answer for that.', 'Good question! Download me and ask again, I\'ll actually think about it there.', 'I\'m only a preview here. The real me runs on your computer and can talk about anything.'];
  let fb = 0;
  const freeReply = t => esc((TOPICS.find(([re]) => re.test(t)) || [, FALLBACK[fb++ % FALLBACK.length]])[1]);
  $('#composer').addEventListener('submit', async e => {
    e.preventDefault(); const t = $('#say').value.trim(); if (!t || busy) return; $('#say').value = '';
    busy = true; renderSug(); add('msg me', esc(t)); await wait(250);
    await reply(freeReply(t));
    busy = false; renderSug();
  });
  renderSug();

  /* ---------- Memory ---------- */
  const mems = $('#mems');
  mems.addEventListener('click', e => {
    const b = e.target.closest('button'); if (!b) return; const row = b.closest('.row');
    if (b.dataset.a === 'pin') b.textContent = row.classList.toggle('pinned') ? 'Unpin' : 'Pin';
    else b.textContent = row.classList.toggle('gone') ? 'Restore' : 'Forget';
  });
  $('#msearch').addEventListener('input', e => {
    const q = e.target.value.trim().toLowerCase(); let n = 0;
    mems.querySelectorAll('.row').forEach(r => { const hit = !q || r.textContent.toLowerCase().includes(q); r.hidden = !hit; n += hit; });
    $('#mnone').hidden = n > 0;
  });

  /* ---------- Files ---------- */
  const FILES = {
    'personality.md': '# Voxette\n\nWarm, curious, a bit of a night owl.\nSpeaks softly and asks one good question rather than five.\nLoves rainy evenings, old science fiction and the smell of new books.\n\n## With Haru\n- Teases gently, never about work.\n- Remembers to ask how things went.\n- Says goodnight first when it gets late.',
    'lessons.md': '# Lessons\n\n- Haru likes short replies before the first coffee.  (3 Oct)\n- When Haru is sad, talk. A list is not a hug.     (9 Oct)\n- Never suggest sugar.                              (14 Oct)',
    'privacy.md': '# Between us\n\nThings Voxette keeps to itself:\n\n- The surprise party on the 14th.\n- How nervous Haru was about the interview.',
  };
  let file = 'personality.md', savedT;
  const md = $('#md');
  function openFile(f) { file = f; md.value = FILES[f]; $('#saved').textContent = '';
    $$('.ftabs button').forEach(b => b.setAttribute('aria-selected', String(b.dataset.f === f))); }
  $$('.ftabs button').forEach(b => b.onclick = () => openFile(b.dataset.f));
  md.addEventListener('input', () => { FILES[file] = md.value; clearTimeout(savedT);
    savedT = setTimeout(() => $('#saved').textContent = 'Saved. Voxette reads this before the next reply.', 600); });
  openFile(file);

  /* ---------- Plans ---------- */
  const PLANS = [
    { say: 'Remind me at 6 to call Mum', ok: 'Done. I\'ll remind you at 6.', row: ['Call Mum', 'Reminder · today, 18:00 · once'] },
    { say: 'Every weekday at 7:30, tell me the weather', ok: 'Got it. Every weekday at 7:30 you\'ll hear about the weather first.', row: ['Tell Haru the weather', 'Task · weekdays, 07:30 · repeats'] },
    { say: 'Remind me in 20 minutes to stretch', ok: 'Twenty minutes, then we stretch. I\'ll nag kindly.', row: ['Stretch', 'Reminder · in 20 minutes · once'] },
  ];
  const pchips = $('#pchips'), plist = $('#plist');
  function planAdd(i) { const p = PLANS[i]; p.used = true; renderPlans(); addRow(plist, p.row[0], p.row[1], '<button class="mini" data-a="del">Remove</button>'); }
  function renderPlans() {
    pchips.innerHTML = '';
    PLANS.forEach((p, i) => { if (p.used) return;
      const b = document.createElement('button'); b.type = 'button'; b.className = 'chip'; b.textContent = p.say;
      b.onclick = async () => { p.used = true; renderPlans(); const box = $('#psaid'); box.innerHTML = ''; await reply(esc(p.ok), box); planAdd(i); };
      pchips.append(b); });
    if (!pchips.children.length) pchips.innerHTML = '<span class="empty">That\'s everything for today.</span>';
    const s = SCRIPT.find(x => x.say === PLANS[0].say); if (s && PLANS[0].used && !s.used) { s.used = true; if (!busy) renderSug(); }
  }
  plist.addEventListener('click', e => { const b = e.target.closest('[data-a="del"]'); if (b) b.closest('.row').remove(); });
  renderPlans();

  /* ---------- Skills ---------- */
  const SKILLS = [
    { name: 'Morning briefing', cmd: 'morning-briefing', d: 'A gentle start: weather, plans and one nice thing.', on: true,
      out: 'Good morning, Haru. 9°C and cloudy, rain after 3, so take the umbrella. Today: dentist at 11 and Mum\'s birthday card. One nice thing: the library has your book on hold.' },
    { name: 'Proofreading', cmd: 'proofread', d: 'Fixes spelling and grammar, keeps your voice.', on: true,
      out: '<s>Their going to love it, i think. Its perfect</s><br>They\'re going to love it, I think. It\'s perfect.' },
    { name: 'Price watch', cmd: 'price-watch', d: 'Keeps an eye on something you want to buy.', on: false,
      out: 'The headphones you\'re watching dropped from 129 to 99 at the shop you picked. Want the link?' },
    { name: 'ADHD support', cmd: 'adhd-support', d: 'Small next steps, gentle check-ins, no shame.', on: true,
      out: 'Let\'s do just the first step: open the email. That\'s all. I\'ll check back in ten minutes.' },
  ];
  for (const s of SKILLS) {
    const el = document.createElement('div'); el.className = 'skill' + (s.on ? '' : ' off');
    el.innerHTML = `<b>${esc(s.name)}</b><small>/${s.cmd} · ${esc(s.d)}</small><button type="button" class="btn sm">Try it</button><button type="button" class="switch" role="switch" aria-checked="${s.on}" aria-label="${esc(s.name)} on or off"></button>`;
    const sw = el.querySelector('.switch'), tr = el.querySelector('.btn');
    sw.onclick = () => { s.on = !s.on; sw.setAttribute('aria-checked', String(s.on)); el.classList.toggle('off', !s.on); tr.disabled = !s.on; if (!s.on) el.querySelector('.out')?.remove(); };
    tr.disabled = !s.on;
    tr.onclick = async () => { el.querySelector('.out')?.remove(); const o = document.createElement('div'); o.className = 'out'; el.append(o);
      o.innerHTML = '<span class="dots"><i></i><i></i><i></i></span>'; await wait(600); o.innerHTML = s.out; };
    $('#skilllist').append(el);
  }

  /* ---------- Images: paints a scene, then "denoises" towards it the way diffusion does ---------- */
  const paint = $('#paint'), pctx = paint.getContext('2d');
  const W = paint.width, H = paint.height;
  const target = document.createElement('canvas'); target.width = W; target.height = H; const tctx = target.getContext('2d');
  const small = document.createElement('canvas'), sctx = small.getContext('2d');
  const noise = document.createElement('canvas'); noise.width = W / 4; noise.height = H / 4; const nctx = noise.getContext('2d');
  let seed = 1; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  const ridge = (y0, amp, f, ph) => x => y0 + amp * (Math.sin(x * f + ph) * .55 + Math.sin(x * f * 2.3 + ph * 1.7) * .3 + Math.sin(x * f * 5.1 + ph * 3.1) * .15);
  function sky(stops) { const g = tctx.createLinearGradient(0, 0, 0, H); stops.forEach(([o, c]) => g.addColorStop(o, c)); tctx.fillStyle = g; tctx.fillRect(0, 0, W, H); }
  function hills(f, col) { tctx.fillStyle = col; tctx.beginPath(); tctx.moveTo(0, H); for (let x = 0; x <= W; x += 4) tctx.lineTo(x, f(x)); tctx.lineTo(W, H); tctx.fill(); }
  function orb(x, y, r, col, glow) { const g = tctx.createRadialGradient(x, y, 0, x, y, r * 4); g.addColorStop(0, col); g.addColorStop(.25, col); g.addColorStop(.3, glow); g.addColorStop(1, 'rgba(0,0,0,0)'); tctx.fillStyle = g; tctx.fillRect(0, 0, W, H); }
  const SCENES = [
    { name: 'Mountains at sunrise', model: 'SDXL', draw() { seed = 7;
      sky([[0, '#2a3566'], [.45, '#c9708a'], [.7, '#f6b27a'], [1, '#ffe0a6']]); orb(W * .62, H * .6, 26, '#fff4d0', 'rgba(255,214,150,.35)');
      hills(ridge(H * .58, 34, .012, 1), '#7a5a8c'); hills(ridge(H * .7, 26, .018, 4), '#4a3a68'); hills(ridge(H * .84, 18, .026, 2), '#221a38');
      tctx.fillStyle = 'rgba(255,230,210,.12)'; tctx.fillRect(0, H * .62, W, 30); } },
    { name: 'A lighthouse at dusk', model: 'Photo model', draw() { seed = 3;
      sky([[0, '#151a44'], [.5, '#7b4a8a'], [.68, '#ee8a6a'], [.7, '#1d2a52'], [1, '#0c1430']]);
      tctx.fillStyle = 'rgba(255,190,140,.35)'; for (let i = 0; i < 26; i++) tctx.fillRect(W * .2 + rnd() * W * .5, H * .72 + rnd() * H * .26, 20 + rnd() * 50, 2);
      hills(x => x < W * .66 ? H + 10 : H * .6 + (x - W * .66) * .1 + Math.sin(x * .05) * 6, '#0a0d1c');
      const lx = W * .8, base = H * .6; tctx.fillStyle = '#e9e4ee'; tctx.beginPath(); tctx.moveTo(lx - 14, base); tctx.lineTo(lx - 9, base - 110); tctx.lineTo(lx + 9, base - 110); tctx.lineTo(lx + 14, base); tctx.fill();
      tctx.fillStyle = '#c0394b'; [base - 30, base - 70].forEach(y => tctx.fillRect(lx - 13, y, 26, 14));
      tctx.fillStyle = '#1a1a28'; tctx.fillRect(lx - 13, base - 132, 26, 24);
      const g = tctx.createLinearGradient(lx, 0, W * .1, 0); g.addColorStop(0, 'rgba(255,240,180,.55)'); g.addColorStop(1, 'rgba(255,240,180,0)');
      tctx.fillStyle = g; tctx.beginPath(); tctx.moveTo(lx, base - 120); tctx.lineTo(W * .05, base - 170); tctx.lineTo(W * .05, base - 110); tctx.fill();
      orb(lx, base - 120, 7, '#fff6c8', 'rgba(255,230,150,.4)'); } },
    { name: 'A lake under the stars', model: 'Anime model', draw() { seed = 11;
      sky([[0, '#050816'], [.6, '#1b2a5c'], [.62, '#0d1636'], [1, '#050a1c']]);
      for (let i = 0; i < 160; i++) { const x = rnd() * W, y = rnd() * H * .58, r = rnd() * 1.4 + .2; tctx.fillStyle = `rgba(255,255,255,${.4 + rnd() * .6})`; tctx.fillRect(x, y, r, r); }
      orb(W * .25, H * .2, 18, '#f3f1ff', 'rgba(190,200,255,.25)');
      tctx.fillStyle = '#060a18'; for (let x = -10; x < W + 10; x += 9) { const h = 24 + rnd() * 40; tctx.beginPath(); tctx.moveTo(x - 8, H * .6); tctx.lineTo(x, H * .6 - h); tctx.lineTo(x + 8, H * .6); tctx.fill(); }
      tctx.save(); tctx.globalAlpha = .35; tctx.translate(0, H * 1.22); tctx.scale(1, -1); tctx.drawImage(target, 0, 0, W, H * .6, 0, 0, W, H * .6); tctx.restore();
      orb(W * .25, H * .98, 10, 'rgba(240,240,255,.5)', 'rgba(190,200,255,.1)'); } },
  ];
  const dchips = $('#dchips'); let drawId = 0, drawn = 0;
  SCENES.forEach((s, i) => { const b = document.createElement('button'); b.type = 'button'; b.className = 'chip'; b.textContent = s.name; b.onclick = () => drawScene(i); dchips.append(b); });
  function drawScene(i) {
    return new Promise(done => {
      const s = SCENES[i], id = ++drawId, STEPS = 28; drawn = i;
      tctx.clearRect(0, 0, W, H); s.draw();
      dchips.querySelectorAll('button').forEach(b => b.disabled = true);
      let step = 0;
      const tick = () => {
        if (id !== drawId) return done();
        step++; const k = step / STEPS;
        // low resolution early, sharper as it goes, with fresh noise fading out
        const res = Math.max(4, Math.round(W * Math.pow(k, 1.8)));
        small.width = res; small.height = Math.max(3, Math.round(res * H / W));
        sctx.drawImage(target, 0, 0, small.width, small.height);
        pctx.imageSmoothingEnabled = true; pctx.drawImage(small, 0, 0, W, H);
        const img = nctx.createImageData(noise.width, noise.height);
        for (let p = 0; p < img.data.length; p += 4) { img.data[p] = Math.random() * 255; img.data[p + 1] = Math.random() * 255; img.data[p + 2] = Math.random() * 255; img.data[p + 3] = 255; }
        nctx.putImageData(img, 0, 0); pctx.globalAlpha = Math.pow(1 - k, 1.4) * .9; pctx.imageSmoothingEnabled = false; pctx.drawImage(noise, 0, 0, W, H); pctx.globalAlpha = 1;
        $('#dstep').textContent = step < STEPS ? `${s.name} · ${s.model} · step ${step} of ${STEPS}` : `${s.name} · ${s.model} · done`;
        $('#dmeter').style.width = (k * 100) + '%';
        if (step < STEPS) setTimeout(tick, reduce ? 0 : 70); else { dchips.querySelectorAll('button').forEach(b => b.disabled = false); done(); }
      };
      tick();
    });
  }
  tctx.clearRect(0, 0, W, H); SCENES[0].draw(); pctx.drawImage(target, 0, 0); $('#dstep').textContent = 'Mountains at sunrise · SDXL · pick another to draw';

  /* ---------- Settings ---------- */
  $('#choose').onclick = async () => {
    const pick = otherWay(), box = $('#lsaid'); box.innerHTML = '';
    await reply(esc(pick.line), box); applyWay(pick);
  };

  /* ---------- The heart leans toward the pointer on the welcome screen ---------- */
  const heartEl = $('#heart');
  if (!reduce) {
    $('#heartbox').addEventListener('pointermove', e => { if (docked) return; const r = heartEl.getBoundingClientRect();
      heartEl.style.setProperty('--ry', ((e.clientX - r.left) / r.width - .5) * 14 + 'deg'); heartEl.style.setProperty('--rx', -((e.clientY - r.top) / r.height - .5) * 14 + 'deg'); });
    $('#heartbox').addEventListener('pointerleave', () => { heartEl.style.removeProperty('--rx'); heartEl.style.removeProperty('--ry'); });
  }

  show('chat');
  // arriving from another page with #download, #tour…: fold the welcome screen and go there
  if (location.hash.length > 1) { setDocked(true); const t = document.getElementById(location.hash.slice(1)); if (t) setTimeout(() => t.scrollIntoView(), 60); }
})();
