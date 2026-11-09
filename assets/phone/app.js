/* VoxCordis on the phone.
 *
 * Everything runs on the PC; this page shows it. One WebSocket to the PC
 * carries every message, sealed with XChaCha20-Poly1305 (cipher.js):
 *
 *   1. hello (plain): {"hello":1,"device":id,"n":nonce} for a paired
 *      phone, {"hello":1,"pair":id,"n":nonce} with a QR code's way in;
 *   2. the PC answers {"n":nonce}, and both ends make the connection's key
 *      from the shared secret and both nonces (HKDF-SHA256);
 *   3. from then on everything is sealed: requests {s,id,op,...} and
 *      answers {re:id,...} or {re,error}; events from the PC {ev,...}.
 *
 * The QR code's secret sits after the "#" of its link, which the browser
 * never sends anywhere, and is forgotten as soon as the page reads it.
 */
(function () {
  'use strict';

  const C = window.VoxCipher;
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const INFO = enc.encode('voxcordis phone v1');
  const PAIR_INFO = enc.encode('voxcordis pair v1');
  const CHECK_INFO = enc.encode('voxcordis check v1');
  const TO_PC = enc.encode('to pc');
  const TO_PHONE = enc.encode('to phone');

  // ------------------------------------------------------------ helpers

  function b64url(bytes) {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) {
      s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    }
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function unb64(text) {
    const s = text.replace(/-/g, '+').replace(/_/g, '/');
    const bin = atob(s + '==='.slice((s.length + 3) % 4));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  function join(a, b) {
    const out = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }
  /** The five letters and numbers both screens show while pairing without
   *  a code: 25 bits of a hash of everything both sides said, in capitals
   *  and digits that can't be mistaken for each other (no 0/O, 1/I). */
  const CHECK_SIGNS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  function checkNumber(phonePublic, pcPublic, phoneNonce, pcNonce) {
    const h = C.sha256(join(join(CHECK_INFO, join(phonePublic, pcPublic)), join(phoneNonce, pcNonce)));
    const n = ((h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3]) >>> 0;
    let out = '';
    for (let i = 0; i < 5; i++) out += CHECK_SIGNS[(n >>> (27 - 5 * i)) & 31];
    return out;
  }


  /** A small element builder: h('div.cls', {attrs}, children…). */
  function h(spec, attrs, ...kids) {
    // 'tag', then any '.class' and one '#id', in any order.
    const parts = spec.match(/^[^.#]*|[.#][^.#]+/g);
    const el = document.createElement(parts[0] || 'div');
    const classes = [];
    for (const p of parts.slice(1)) {
      if (p[0] === '#') el.id = p.slice(1);
      else classes.push(p.slice(1));
    }
    if (classes.length) el.className = classes.join(' ');
    if (attrs) {
      for (const k in attrs) {
        const v = attrs[k];
        if (v == null || v === false) continue;
        if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
        else if (k === 'text') el.textContent = v;
        else if (k === 'html') el.innerHTML = v;
        else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
        else el.setAttribute(k, v === true ? '' : v);
      }
    }
    for (const kid of kids.flat(Infinity)) {
      if (kid == null || kid === false) continue;
      el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
    }
    return el;
  }
  const $ = (sel, el) => (el || document).querySelector(sel);
  const esc = (t) =>
    String(t).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

  /** *italic* and **bold**, as the PC shows story and chat text. */
  function marked(text) {
    return esc(text)
      .replace(/\*\*(\S(?:[^*]*?\S)?)\*\*/g, '<b>$1</b>')
      .replace(/\*(\S(?:[^*]*?\S)?)\*/g, '<em>$1</em>');
  }

  const ICONS = {
    chat: '<path d="M5 18l-1.5 3.5L8 20a9 9 0 1 0-3-2z"/>',
    images: '<rect x="3" y="4" width="18" height="16" rx="3"/><circle cx="9" cy="10" r="2"/><path d="M21 16l-5-5-9 9"/>',
    globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3.2 3 14.8 0 18M12 3c-3 3.2-3 14.8 0 18"/>',
    down: '<path d="M6 9l6 6 6-6"/>',
    back: '<path d="M15 6l-6 6 6 6"/>',
    send: '<path d="M12 19V5M6 11l6-6 6 6"/>',
    calendar: '<rect x="3.5" y="5" width="17" height="15" rx="3"/><path d="M8 3v4M16 3v4M3.5 10h17"/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="2" fill="currentColor"/>',
    retry: '<path d="M4 12a8 8 0 1 0 2.4-5.7L4 8.6M4 4v4.6h4.6"/>',
    brush: '<path d="M14 4l6 6-9 9H5v-6z"/><path d="M12 6l6 6"/>',
    close: '<path d="M6 6l12 12M18 6L6 18"/>',
    forward: '<path d="M4 6l8 6-8 6zM12 6l8 6-8 6z" fill="currentColor" stroke="none"/>',
    dice: '<rect x="4" y="4" width="16" height="16" rx="4"/><circle cx="9" cy="9" r="1.2" fill="currentColor"/><circle cx="15" cy="15" r="1.2" fill="currentColor"/><circle cx="15" cy="9" r="1.2" fill="currentColor"/><circle cx="9" cy="15" r="1.2" fill="currentColor"/>',
    pin: '<path d="M9 4h6l-1 6 4 4H6l4-4zM12 14v7"/>',
    play: '<path d="M8 5l12 7-12 7z" fill="#fff" stroke="none"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
    sparkle: '<path d="M12 3l2 6 6 2-6 2-2 6-2-6-6-2 6-2z"/>',
  };
  function icon(name, size) {
    const el = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    el.setAttribute('viewBox', '0 0 24 24');
    el.setAttribute('fill', 'none');
    el.setAttribute('stroke', 'currentColor');
    el.setAttribute('stroke-width', '1.9');
    el.setAttribute('stroke-linecap', 'round');
    el.setAttribute('stroke-linejoin', 'round');
    el.setAttribute('aria-hidden', 'true');
    if (size) {
      el.setAttribute('width', size);
      el.setAttribute('height', size);
    }
    el.innerHTML = ICONS[name];
    return el;
  }

  let toastTimer;
  function toast(text) {
    const t = $('#toast');
    t.textContent = text;
    t.classList.add('on');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove('on'), 4000);
  }

  function store(key, value) {
    try {
      if (value === undefined) return JSON.parse(localStorage.getItem(key) || 'null');
      if (value === null) localStorage.removeItem(key);
      else localStorage.setItem(key, JSON.stringify(value));
    } catch (e) {
      return null;
    }
  }

  function phoneName() {
    const ua = navigator.userAgent;
    if (/iPhone/.test(ua)) return 'iPhone';
    if (/iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return 'iPad';
    const m = ua.match(/Android [\d.]+; ([^;)]+?)(?: Build|\))/);
    if (m && m[1] && !/^(K|wv)$/.test(m[1].trim())) return m[1].trim();
    if (/Android/.test(ua)) return 'Android phone';
    return 'Phone';
  }

  function when(ms) {
    const d = new Date(ms);
    const now = new Date();
    const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    const days = Math.round((new Date(now.toDateString()) - new Date(d.toDateString())) / 864e5);
    if (days === 0) return time;
    if (days === 1) return 'Yesterday ' + time;
    if (days < 7) return d.toLocaleDateString([], { weekday: 'long' });
    return d.toLocaleDateString([], { day: 'numeric', month: 'short', year: now.getFullYear() === d.getFullYear() ? undefined : 'numeric' });
  }

  // ------------------------------------------------------- the link

  const link = {
    ws: null,
    key: null,
    outSeq: 0,
    inSeq: 0,
    calls: new Map(),
    nextId: 1,
    ready: false,
    tries: 0,
    timer: null,
  };

  /** What the page knows: the PC's state, the chat, pictures, stories. */
  const S = {
    phase: 'start', // start | pair | waiting | refused | ready
    why: '',
    state: null,
    online: false,
    tab: store('vox.tab') || 'chat',
    chat: { order: [], msgs: new Map(), busy: false, phase: 'idle', note: null, error: null, canRetry: false, stopping: false, forPhone: false },
    day: null, // { day, label, msgs } while looking at an earlier day
    staged: [], // photos to send: { name, data, url }
    sending: false,
    pics: null,
    drawing: null,
    drawOpts: null,
    view: null, // 'draw' over Images
    voces: null,
    story: null,
    storyMode: 'say',
    roll: false,
    asks: new Map(),
    tucked: false, // tabs slid away while reading back
    typing: false,
  };

  function connect() {
    clearTimeout(link.timer);
    const device = store('vox.device');
    const pair = sessionPair;
    if (!device && !pair) {
      S.phase = 'pair';
      render();
      return;
    }
    let ws;
    try {
      ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws');
    } catch (e) {
      return retryLater();
    }
    ws.binaryType = 'arraybuffer';
    link.ws = ws;
    link.key = null;
    link.ready = false;
    link.outSeq = 0;
    link.inSeq = 0;
    const phoneNonce = C.randomBytes(24);
    const near = !device && pair.near;
    // Pairing without a code: a key worked out with the PC (X25519), its
    // half promised before the PC shows its own (so nobody in between can
    // make the numbers match), then checked by eye on both screens.
    const mine = near ? C.x25519.utils.randomPrivateKey() : null;
    const myPublic = near ? C.x25519.getPublicKey(mine) : null;
    let secret = device ? unb64(device.key) : near ? null : pair.secret;
    let pcNonce = null;
    let step = near ? 'near' : 'hello';

    ws.onopen = () => {
      const hello = { hello: 1, n: b64url(phoneNonce) };
      if (device) hello.device = device.id;
      else if (near) {
        hello.near = 1;
        hello.c = b64url(C.sha256(myPublic));
      } else hello.pair = pair.id;
      ws.send(JSON.stringify(hello));
    };
    ws.onmessage = async (e) => {
      if (link.ws !== ws) return;
      if (step !== 'sealed') {
        let j;
        try {
          j = JSON.parse(e.data);
        } catch (err) {
          return ws.close();
        }
        if (j.error) {
          if (j.error === 'unpaired') {
            store('vox.device', null);
            S.why = 'This phone was removed on your PC. Pair it again to come back.';
          } else if (j.error === 'closed') {
            S.why = 'Your PC isn\'t pairing right now. On your PC, choose “Pair a phone” first, then tap again.';
          } else {
            S.why = 'That code has run out or was already used. Make a new one on your PC.';
          }
          sessionPair = null;
          S.phase = 'pair';
          link.giveUp = true;
          render();
          return;
        }
        if (step === 'near') {
          // The PC's half: show ours, work out the secret and the number.
          let pcPublic;
          try {
            pcNonce = unb64(j.n);
            pcPublic = unb64(j.pk);
            const shared = C.x25519.getSharedSecret(mine, pcPublic);
            secret = C.hkdf(C.sha256, shared, join(myPublic, pcPublic), PAIR_INFO, 32);
          } catch (err) {
            return ws.close();
          }
          S.check = checkNumber(myPublic, pcPublic, phoneNonce, pcNonce);
          step = 'shown';
          ws.send(JSON.stringify({ pk: b64url(myPublic) }));
          return;
        }
        if (step === 'hello') pcNonce = unb64(j.n);
        step = 'sealed';
        link.key = C.hkdf(C.sha256, secret, join(phoneNonce, pcNonce), INFO, 32);
        if (!device) {
          S.phase = 'waiting';
          render();
        }
        hello_();
        return;
      }
      if (!(e.data instanceof ArrayBuffer) || !link.key) return;
      const frame = new Uint8Array(e.data);
      let msg;
      try {
        const plain = C.xchacha20poly1305(link.key, frame.subarray(0, 24), TO_PHONE).decrypt(frame.subarray(24));
        msg = JSON.parse(dec.decode(plain));
      } catch (err) {
        return ws.close();
      }
      if (typeof msg.s !== 'number' || msg.s <= link.inSeq) return ws.close();
      link.inSeq = msg.s;
      if (msg.re != null) {
        const call = link.calls.get(msg.re);
        if (call) {
          link.calls.delete(msg.re);
          clearTimeout(call.timer);
          if (msg.error) call.no(new Error(msg.error));
          else call.yes(msg);
        }
      } else if (msg.ev) {
        onEvent(msg);
      }
    };
    ws.onclose = () => {
      if (link.ws !== ws) return;
      const was = link.ready;
      link.ready = false;
      link.key = null;
      S.online = false;
      for (const [, call] of link.calls) {
        clearTimeout(call.timer);
        call.no(new Error('Lost the connection to your PC.'));
      }
      link.calls.clear();
      if (link.giveUp) {
        link.giveUp = false;
        return;
      }
      if (S.phase === 'waiting') {
        S.phase = 'refused';
        S.why = 'Your PC declined this request, or nobody answered in time.';
        sessionPair = null;
        render();
        return;
      }
      if (was || S.phase === 'ready') render();
      retryLater();
    };
    ws.onerror = () => {};
  }

  function retryLater() {
    const waits = [1000, 2000, 4000, 8000, 15000];
    const wait = waits[Math.min(link.tries, waits.length - 1)];
    link.tries++;
    clearTimeout(link.timer);
    link.timer = setTimeout(connect, wait);
    if (S.phase === 'start') {
      S.why = 'Can\'t reach VoxCordis on your PC. Is it running, with phone access on?';
      render();
    }
  }

  function send(msg) {
    const ws = link.ws;
    if (!ws || ws.readyState !== 1 || !link.key) throw new Error('Not connected to your PC.');
    const nonce = C.randomBytes(24);
    const body = enc.encode(JSON.stringify(Object.assign({ s: ++link.outSeq }, msg)));
    const sealed = C.xchacha20poly1305(link.key, nonce, TO_PC).encrypt(body);
    ws.send(join(nonce, sealed));
  }

  /** Asks the PC [op]; resolves with its answer. */
  function call(op, args, timeout) {
    return new Promise((yes, no) => {
      const id = link.nextId++;
      const timer = setTimeout(() => {
        link.calls.delete(id);
        no(new Error('Your PC took too long to answer.'));
      }, timeout || 60000);
      link.calls.set(id, { yes, no, timer });
      try {
        send(Object.assign({ id, op }, args || {}));
      } catch (e) {
        clearTimeout(timer);
        link.calls.delete(id);
        no(e);
      }
    });
  }

  async function hello_() {
    try {
      // Pairing waits for someone at the PC to say yes.
      const r = await call('hello', { name: phoneName() }, 200000);
      if (r.paired) {
        store('vox.device', { id: r.paired.id, key: r.paired.key, name: r.paired.name });
        sessionPair = null;
      }
      link.ready = true;
      link.tries = 0;
      S.online = true;
      S.phase = 'ready';
      S.why = '';
      setState(r);
      S.chat.msgs.clear();
      chatEvent(r.chat || {});
      if (S.story) {
        // Back after a lost connection: pick the story up again.
        const id = S.story.id;
        call('voces.open', { story: id })
          .then((x) => storyEvent(x.story, true))
          .catch(() => (S.story = null));
      }
      if (S.tab === 'images') loadPics();
      if (S.tab === 'voces' && !S.story) loadVoces();
      render();
    } catch (e) {
      if (S.phase === 'waiting') return; // onclose says what happened
      toast(e.message);
    }
  }

  function onEvent(m) {
    switch (m.ev) {
      case 'chat':
        chatEvent(m);
        break;
      case 'state':
        setState(m);
        S.drawOpts = null;
        if (S.tab === 'images') loadPics();
        if (S.tab === 'voces' && !S.story) loadVoces();
        render();
        break;
      case 'drawing':
        S.drawing = m.busy ? m : null;
        if (S.tab === 'images' && !S.view) renderDrawingCard();
        break;
      case 'drawn':
        if (m.error) toast('Drawing didn\'t work: ' + m.error);
        else {
          toast('Your picture is ready.');
          if (S.tab === 'images') loadPics();
        }
        break;
      case 'story':
        if (S.story && m.id === S.story.id) storyEvent(m, false);
        break;
      case 'notice':
        toast(m.text);
        break;
      case 'ask':
        showAsk(m);
        break;
      case 'asked': {
        const a = S.asks.get(m.ask);
        if (a) a.remove();
        S.asks.delete(m.ask);
        break;
      }
    }
  }

  function setState(r) {
    S.state = {
      companion: r.companion,
      companions: r.companions || [],
      human: r.human,
      look: r.look || {},
      voces: !!r.voces,
      draw: !!r.draw,
    };
    applyLook(S.state.look);
    if (S.tab === 'voces' && !S.state.voces) S.tab = 'chat';
  }

  function hexA(hex, a) {
    const n = parseInt((hex || '#000000').slice(1), 16);
    return 'rgba(' + ((n >> 16) & 255) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + a + ')';
  }

  function applyLook(look) {
    const root = document.documentElement;
    const light =
      look.theme === 'light' || (look.theme === 'system' && window.matchMedia('(prefers-color-scheme: light)').matches);
    root.dataset.theme = light ? 'light' : 'dark';
    if (look.accent) {
      root.style.setProperty('--accent', look.accent);
      root.style.setProperty('--mine', hexA(look.accent, light ? 0.18 : 0.26));
      root.style.setProperty('--mine-line', hexA(look.accent, 0.3));
      const n = parseInt(look.accent.slice(1), 16);
      const lum = (0.299 * ((n >> 16) & 255) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)) / 255;
      root.style.setProperty('--on-accent', lum > 0.6 ? '#1d1430' : '#ffffff');
      // Pale accents need more ink to read on a light page.
      const k = light && lum > 0.45 ? 0.5 : 1;
      const ink = [(n >> 16) & 255, (n >> 8) & 255, n & 255].map((x) => Math.round(x * k));
      root.style.setProperty('--accent-ink', 'rgb(' + ink.join(',') + ')');
    }
    const g = look.glows || [];
    if (g[0]) root.style.setProperty('--glow1', hexA(g[0], light ? 0.18 : 0.3));
    if (g[1]) root.style.setProperty('--glow2', hexA(g[1], light ? 0.14 : 0.18));
    const meta = $('meta[name="theme-color"]');
    if (meta) meta.content = light ? '#f6f3fa' : '#14111c';
  }

  // ------------------------------------------------------- pictures

  const picCache = new Map(); // "ref|full" -> object URL
  const picWaiting = [];
  let picBusy = 0;

  function picture(ref, full) {
    const key = ref + (full ? '|f' : '|t');
    if (picCache.has(key)) return picCache.get(key);
    const p = new Promise((yes, no) => {
      picWaiting.push({ ref, full, yes, no });
      pump();
    });
    picCache.set(key, p);
    p.catch(() => picCache.delete(key));
    return p;
  }
  function pump() {
    while (picBusy < 3 && picWaiting.length) {
      const job = picWaiting.shift();
      picBusy++;
      call('pic', { ref: job.ref, full: job.full }, 120000)
        .then((r) => {
          const bin = atob(r.data);
          const bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          job.yes({ url: URL.createObjectURL(new Blob([bytes], { type: r.mime })), video: r.mime.startsWith('video/') });
        })
        .catch(job.no)
        .finally(() => {
          picBusy--;
          pump();
        });
    }
  }

  const seen = 'IntersectionObserver' in window
    ? new IntersectionObserver(
        (entries) => {
          for (const e of entries) {
            if (!e.isIntersecting) continue;
            seen.unobserve(e.target);
            fill(e.target);
          }
        },
        { rootMargin: '300px' },
      )
    : null;

  /** A picture tile; loads its small copy once it nears the screen. */
  function picTile(ref, opts) {
    opts = opts || {};
    const el = h('button.pic.loading', {
      type: 'button',
      'aria-label': opts.label || (opts.video ? 'Clip' : 'Picture'),
      onclick: () => openViewer(ref, opts.video),
    });
    el.dataset.ref = ref;
    if (opts.video) el.dataset.video = '1';
    if (seen) seen.observe(el);
    else fill(el);
    return el;
  }
  function fill(el) {
    const ref = el.dataset.ref;
    if (el.dataset.video) {
      el.classList.remove('loading');
      el.append(h('span.play', null, icon('play')));
      el.style.background = 'linear-gradient(140deg, #2a2340, #4b3a6e)';
      return;
    }
    picture(ref, false).then(
      (p) => {
        el.classList.remove('loading');
        el.prepend(h('img', { src: p.url, alt: '' }));
      },
      () => {
        el.classList.remove('loading');
        el.append(h('span.note', { text: 'Missing', style: { padding: '8px', display: 'block' } }));
      },
    );
  }

  function openViewer(ref, video) {
    const close = () => v.remove();
    const v = h(
      'div.viewer',
      { role: 'dialog', 'aria-label': 'Picture', onclick: (e) => e.target === v && close() },
      h('div.spinner'),
      h('button.icon-btn.close', { type: 'button', 'aria-label': 'Close', onclick: close }, icon('close')),
    );
    document.body.append(v);
    picture(ref, true).then(
      (p) => {
        const sp = $('.spinner', v);
        if (sp) sp.remove();
        v.prepend(
          p.video
            ? h('video', { src: p.url, controls: true, autoplay: true, loop: true, playsinline: true })
            : h('img', { src: p.url, alt: '' }),
        );
      },
      (e) => {
        close();
        toast(e.message);
      },
    );
  }

  // ------------------------------------------------------- rendering

  function render() {
    const app = $('#app');
    const keep = document.activeElement && document.activeElement.id ? document.activeElement.id : null;
    app.textContent = '';
    if (S.phase !== 'ready') {
      app.classList.remove('tucked', 'notabs', 'hastabs');
      app.append(renderHello());
      return;
    }
    if (!S.online) app.append(h('div.offline', { text: 'Reconnecting to your PC…' }));
    let screen;
    if (S.tab === 'images') screen = S.view === 'draw' ? renderDraw() : renderImages();
    else if (S.tab === 'voces') screen = S.story ? renderStory() : renderVoces();
    else screen = renderChat();
    app.append(screen);
    const tabs = !(S.tab === 'voces' && S.story) && S.view !== 'draw';
    if (tabs) app.append(renderTabs());
    app.classList.toggle('notabs', !tabs);
    app.classList.toggle('hastabs', tabs);
    showTabs();
    if (keep) {
      const el = document.getElementById(keep);
      if (el) el.focus({ preventScroll: true });
    }
  }

  function renderHello() {
    const heart = h('img.heart', { src: 'heart.svg', alt: '' });
    if (S.phase === 'start') {
      return h('div.hello', null, heart, h('div.spinner'), h('p', { text: S.why || 'Connecting to your PC…' }));
    }
    if (S.phase === 'waiting') {
      return h(
        'div.hello',
        null,
        heart,
        h('h1', { text: 'Say yes on your PC' }),
        S.check ? h('p.check', { text: S.check, 'aria-label': 'Code to check: ' + S.check.split('').join(' ') }) : null,
        h('p', {
          text: S.check
            ? 'Your PC shows a code too. If it\'s the same as this one, allow this phone there.'
            : 'Your PC is asking whether this phone may use VoxCordis. Allow it there, and you\'re in.',
        }),
        h('div.spinner'),
      );
    }
    return h(
      'div.hello',
      null,
      heart,
      h('h1', { text: 'VoxCordis on your phone' }),
      S.why ? h('p', { text: S.why, style: { color: 'var(--danger)' } }) : null,
      h(
        'ol',
        null,
        h('li', { text: 'On your PC, open VoxCordis, then Settings › Connections › Phone access.' }),
        h('li', { text: 'Choose “Pair a phone”.' }),
        h('li', { text: 'Tap Pair with my PC below, check that both screens show the same code, and allow it on your PC.' }),
      ),
      h(
        'button.btn.go.pairbtn',
        {
          type: 'button',
          onclick: () => {
            sessionPair = { near: true };
            startPairing();
          },
        },
        icon('link', 20),
        'Pair with my PC',
      ),
      h('p', { class: 'note', text: 'Your phone needs to be on the same Wi-Fi as your PC. You can also scan the code on your PC with this phone\'s camera.' }),
    );
  }

  function renderTabs() {
    const tab = (id, label, ic) =>
      h(
        'button',
        {
          type: 'button',
          'aria-current': S.tab === id ? 'page' : null,
          onclick: () => {
            if (S.tab === id) return;
            S.tab = id;
            S.tucked = false;
            S.view = null;
            store('vox.tab', id);
            if (id === 'images') loadPics();
            if (id === 'voces' && !S.story) loadVoces();
            render();
            if (id === 'chat') scrollChat(true);
          },
        },
        h('span', null, icon(ic)),
        label,
      );
    return h(
      'nav.tabs',
      { 'aria-label': 'Sections' },
      tab('chat', 'Chat', 'chat'),
      tab('images', 'Images', 'images'),
      S.state.voces ? tab('voces', 'Voces Mundi', 'globe') : null,
    );
  }

  function avatar(person, opts) {
    opts = opts || {};
    const el = h('span.avatar' + (opts.round ? '.round' : ''), {
      style: opts.size ? { width: opts.size + 'px', height: opts.size + 'px' } : null,
    });
    if (opts.accent) el.style.borderColor = opts.accent;
    if (person && person.portrait) {
      picture(person.portrait, false).then((p) => el.prepend(h('img', { src: p.url, alt: '' })), () => {});
    } else {
      el.append(h('img', { src: 'heart.svg', alt: '', style: { width: '62%', height: 'auto' } }));
    }
    if (opts.dot) el.append(h('span.dot'));
    return el;
  }

  // ------------------------------------------------------- chat

  const PHASES = {
    waking: (n) => 'waking up…',
    thinking: (n) => 'thinking…',
    typing: (n) => 'typing…',
    remembering: (n) => 'remembering…',
    looking: (n) => 'looking at your picture…',
  };

  function chatStatus() {
    const c = S.chat;
    if (S.day) return S.day.label;
    if (c.busy) return (c.note ? c.note : (PHASES[c.phase] || PHASES.thinking)(S.state.companion.name));
    return 'on your PC';
  }

  function chatEvent(m) {
    const c = S.chat;
    if (m.order) c.order = m.order;
    for (const msg of m.msgs || []) c.msgs.set(msg.id, msg);
    for (const k of ['busy', 'phase', 'note', 'error', 'canRetry', 'stopping', 'forPhone']) {
      if (k in m) c[k] = m[k];
    }
    for (const id of [...c.msgs.keys()]) if (!c.order.includes(id)) c.msgs.delete(id);
    if (S.phase === 'ready' && S.tab === 'chat' && !S.day) updateChat();
  }

  function renderChat() {
    const st = S.state;
    const comp = st.companion;
    const header = h(
      'header.bar',
      null,
      h(
        'button.who-btn',
        { type: 'button', 'aria-label': 'Switch companion', onclick: companionSheet },
        avatar(comp, { dot: S.online }),
        h(
          'span.names',
          null,
          h('b', null, comp.name, st.companions.length > 1 ? icon('down', 16) : null),
          h('span#chat-status', { text: chatStatus() }),
        ),
      ),
      h('button.icon-btn', { type: 'button', 'aria-label': 'Earlier days', onclick: daysSheet }, icon('calendar')),
    );
    const list = h('div.msgs#msgs');
    const scroller = h('div.scroll#chat-scroll', null, list);
    if (!S.day) stick(scroller, list);
    tuckOn(scroller, 'bottom');
    const screen = h('section.screen', { 'aria-label': 'Chat with ' + comp.name }, header, scroller);
    if (S.day) {
      list.append(h('div.divider', { text: S.day.label }));
      for (const m of S.day.msgs) list.append(messageEl(m, false));
      screen.append(
        dock(
          h(
            'div.composer',
            null,
            h('div.center-row', null, h('button.pill', { type: 'button', onclick: backToToday }, 'Back to today')),
          ),
          scroller,
        ),
      );
      return screen;
    }
    screen.append(dock(renderComposer(), scroller));
    requestAnimationFrame(() => {
      updateChat(true);
      scrollChat(true);
    });
    return screen;
  }

  function backToToday() {
    S.day = null;
    render();
    scrollChat(true);
  }

  const msgEls = new Map(); // id -> { el, sig }

  function updateChat(fresh) {
    const list = $('#msgs');
    if (!list) return;
    const scroller = $('#chat-scroll');
    const nearEnd = !scroller || scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 120;
    if (fresh) {
      msgEls.clear();
      list.textContent = '';
    }
    const c = S.chat;
    const lastId = c.order[c.order.length - 1];
    const wanted = [];
    if (c.order.length) wanted.push('divider');
    for (const id of c.order) {
      const m = c.msgs.get(id);
      if (!m) continue;
      const live = c.busy && id === lastId && m.role === 'assistant';
      const sig = JSON.stringify([m.text, m.pics, m.think, live]);
      let entry = msgEls.get(id);
      if (!entry || entry.sig !== sig) {
        const el = messageEl(m, live);
        if (entry) entry.el.replaceWith(el);
        entry = { el, sig };
        msgEls.set(id, entry);
      }
      wanted.push(entry.el);
    }
    for (const [id, entry] of msgEls) {
      if (!c.order.includes(id)) {
        entry.el.remove();
        msgEls.delete(id);
      }
    }
    // Put them in order, moving only what is out of place.
    let divider = $('.divider', list);
    if (!divider) divider = h('div.divider', { text: 'Today' });
    let i = 0;
    for (const w of wanted) {
      const el = w === 'divider' ? divider : w;
      if (list.children[i] !== el) list.insertBefore(el, list.children[i] || null);
      i++;
    }
    while (list.children.length > i) list.lastChild.remove();
    const status = $('#chat-status');
    if (status) status.textContent = chatStatus();
    const comp = $('#composer-state');
    if (comp) comp.replaceWith(composerState());
    const sendBtn = $('#send');
    if (sendBtn) sendBtn.disabled = c.busy || S.sending;
    if (nearEnd) scrollChat(false);
  }

  /** Keeps [scroller] at its end while it is there, as pictures load
   *  and replies grow; scrolling up lets go. */
  function stick(scroller, list) {
    scroller._stick = true;
    let last = 0;
    scroller.addEventListener('scroll', () => {
      const atEnd = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;
      if (scroller.scrollTop < last - 2) scroller._stick = atEnd;
      else if (atEnd) scroller._stick = true;
      last = scroller.scrollTop;
    }, { passive: true });
    if ('ResizeObserver' in window) {
      new ResizeObserver(() => {
        if (scroller._stick) scroller.scrollTop = scroller.scrollHeight;
      }).observe(list);
    }
  }

  // The tabs slide away while someone reads back (up through a chat, down
  // a list) or types, and come back on scrolling toward home: the newest
  // message, or the top of a list. No hidden gesture to learn.
  function tuckOn(scroller, home) {
    let last = scroller.scrollTop;
    let run = 0;
    scroller.addEventListener('scroll', () => {
      const top = scroller.scrollTop;
      const d = top - last;
      last = top;
      if (scroller.scrollHeight <= scroller.clientHeight + 4) return;
      const atHome = home === 'bottom'
        ? scroller.scrollHeight - top - scroller.clientHeight < 60
        : top < 40;
      if (atHome) return setTucked(false);
      const away = home === 'bottom' ? d < 0 : d > 0;
      // How far in one direction, so a small wobble changes nothing.
      if (away) run = run > 0 ? run + Math.abs(d) : Math.abs(d);
      else run = run < 0 ? run - Math.abs(d) : -Math.abs(d);
      if (run > 40) setTucked(true);
      else if (run < -40) setTucked(false);
    }, { passive: true });
  }

  // The message box floats over the chat; the chat keeps room for it at
  // its end, as tall as the box is now (it grows with the text and photos).
  function dock(box, scroller) {
    if ('ResizeObserver' in window) {
      new ResizeObserver(() => {
        $('#app').style.setProperty('--dock-h', box.offsetHeight + 'px');
        if (scroller._stick) scroller.scrollTop = scroller.scrollHeight;
      }).observe(box);
    }
    return box;
  }

  function setTucked(on) {
    if (S.tucked === on) return;
    S.tucked = on;
    showTabs();
  }

  function showTabs() {
    const app = $('#app');
    const tabs = $('.tabs', app);
    if (tabs && tabs.offsetHeight) app.style.setProperty('--tabs-h', tabs.offsetHeight + 'px');
    app.classList.toggle('tucked', !!tabs && (S.tucked || S.typing));
  }

  // Typing: the tabs make room, and on an iPhone (whose keyboard covers
  // the page instead of making it smaller) the page fits above the keyboard.
  const typingIn = (el) => el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && /^(text|search|number|)$/.test(el.type)));
  document.addEventListener('focusin', (e) => {
    if (!typingIn(e.target) || !window.matchMedia('(pointer: coarse)').matches) return;
    S.typing = true;
    showTabs();
  });
  document.addEventListener('focusout', () => {
    setTimeout(() => {
      if (typingIn(document.activeElement)) return;
      S.typing = false;
      showTabs();
    }, 60);
  });
  // A home-screen app on an iPhone gets a layout viewport shorter than
  // the screen by about the status bar, yet draws to the bottom edge: the
  // page reaches down by what is missing.
  const standalone = navigator.standalone === true || window.matchMedia('(display-mode: standalone)').matches;
  function reach() {
    if (!standalone) return;
    const tall = window.innerHeight > window.innerWidth;
    const full = tall ? Math.max(screen.width, screen.height) : Math.min(screen.width, screen.height);
    const short = full - window.innerHeight;
    document.documentElement.style.setProperty('--short', short > 0 && short < 120 ? short + 'px' : '0px');
  }
  reach();
  window.addEventListener('resize', reach);
  window.addEventListener('orientationchange', () => setTimeout(reach, 300));

  if (window.visualViewport) {
    const vv = window.visualViewport;
    const fit = () => {
      const root = document.documentElement;
      const kbd = window.innerHeight - vv.height > 120 && S.typing;
      root.classList.toggle('kbd', kbd);
      if (kbd) {
        root.style.setProperty('--vv-h', vv.height + 'px');
        root.style.setProperty('--vv-top', vv.offsetTop + 'px');
        const s = $('#chat-scroll') || $('#story-scroll');
        if (s && s._stick) s.scrollTop = s.scrollHeight;
      }
    };
    vv.addEventListener('resize', fit);
    vv.addEventListener('scroll', fit);
    document.addEventListener('focusout', () => setTimeout(fit, 80));
  }

  function scrollChat(jump) {
    const s = $('#chat-scroll') || $('#story-scroll');
    if (!s) return;
    requestAnimationFrame(() => s.scrollTo({ top: s.scrollHeight, behavior: jump ? 'auto' : 'smooth' }));
  }

  function messageEl(m, live) {
    const mine = m.role === 'user';
    const el = h('div.msg.' + (mine ? 'me' : 'it'));
    if (m.think && !mine) {
      el.append(h('details.think', null, h('summary', { text: 'Thoughts' }), h('div', { text: m.think })));
    }
    if (m.pics && m.pics.length) {
      el.append(h('div.pics', null, m.pics.map((r) => picTile(r))));
    }
    const text = (m.text || '').trim();
    if (text || live) {
      const b = h('div.bubble', { html: marked(text) });
      if (live) b.append(h('span.caret'));
      el.append(b);
    }
    if (m.files && m.files.length) el.append(h('div.files', { text: '📎 ' + m.files.join(', ') }));
    if (m.via === 'phone' && mine) el.append(h('span.meta', { text: 'from your phone · ' + when(m.ts) }));
    return el;
  }

  function composerState() {
    const c = S.chat;
    const box = h('div#composer-state');
    if (c.busy) {
      box.append(
        h(
          'div.center-row',
          null,
          h('button.pill', { type: 'button', disabled: c.stopping, onclick: () => call('chat.stop').catch((e) => toast(e.message)) }, icon('stop'), c.stopping ? 'Stopping…' : 'Stop'),
        ),
      );
    } else if (c.error) {
      box.append(h('div.error', { text: c.error }));
      if (c.canRetry) {
        box.append(
          h(
            'div.center-row',
            { style: { marginTop: '6px' } },
            h('button.pill', { type: 'button', onclick: () => call('chat.retry').catch((e) => toast(e.message)) }, icon('retry'), 'Try again'),
          ),
        );
      }
    }
    return box;
  }

  function renderComposer() {
    const name = S.state.companion.name;
    const input = h('textarea#chat-input', {
      rows: 1,
      placeholder: 'Message ' + name + '…',
      'aria-label': 'Message',
      enterkeyhint: 'send',
      oninput: () => grow(input),
    });
    input.value = store('vox.draft') || '';
    input.addEventListener('input', () => store('vox.draft', input.value));
    const fileIn = h('input', { type: 'file', accept: 'image/*', multiple: true, class: 'sr', onchange: () => addPhotos(fileIn) });
    const staged = h('div.staged#staged');
    drawStaged(staged);
    const box = h(
      'div.composer',
      null,
      composerState(),
      staged,
      h(
        'div.row',
        null,
        h('button.round-btn', { type: 'button', 'aria-label': 'Share a picture', onclick: () => fileIn.click() }, icon('images')),
        fileIn,
        input,
        h('button.round-btn.go#send', { type: 'button', 'aria-label': 'Send', disabled: S.chat.busy, onclick: () => sendChat(input) }, icon('send')),
      ),
    );
    requestAnimationFrame(() => grow(input));
    return box;
  }

  function grow(t) {
    t.style.height = 'auto';
    t.style.height = Math.min(t.scrollHeight, 140) + 'px';
  }

  function drawStaged(box) {
    box = box || $('#staged');
    if (!box) return;
    box.textContent = '';
    S.staged.forEach((p, i) => {
      box.append(
        h(
          'span.pic',
          null,
          h('img', { src: p.url, alt: p.name }),
          h('button.x', { type: 'button', 'aria-label': 'Remove ' + p.name, onclick: () => { URL.revokeObjectURL(p.url); S.staged.splice(i, 1); drawStaged(); } }, '×'),
        ),
      );
    });
  }

  /** Photos are made smaller on the phone before they travel. */
  async function addPhotos(input) {
    const files = [...input.files].slice(0, 6 - S.staged.length);
    input.value = '';
    for (const f of files) {
      try {
        const blob = await shrink(f, 2048);
        const bytes = new Uint8Array(await blob.arrayBuffer());
        S.staged.push({ name: f.name || 'photo.jpg', data: b64url(bytes), url: URL.createObjectURL(blob) });
      } catch (e) {
        toast('That picture couldn\'t be read.');
      }
    }
    drawStaged();
  }

  function shrink(file, edge) {
    return new Promise((yes, no) => {
      const url = URL.createObjectURL(file);
      const img = new Image();
      img.onload = () => {
        URL.revokeObjectURL(url);
        const scale = Math.min(1, edge / Math.max(img.naturalWidth, img.naturalHeight));
        if (scale === 1 && file.size < 3e6 && /^image\/(jpeg|png|webp)$/.test(file.type)) return yes(file);
        const c = document.createElement('canvas');
        c.width = Math.round(img.naturalWidth * scale);
        c.height = Math.round(img.naturalHeight * scale);
        c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
        c.toBlob((b) => (b ? yes(b) : no(new Error('No picture'))), 'image/jpeg', 0.86);
      };
      img.onerror = () => {
        URL.revokeObjectURL(url);
        no(new Error('Not a picture'));
      };
      img.src = url;
    });
  }

  async function sendChat(input) {
    const text = input.value.trim();
    if ((!text && !S.staged.length) || S.chat.busy || S.sending) return;
    S.sending = true;
    const sendBtn = $('#send');
    if (sendBtn) sendBtn.disabled = true;
    try {
      await call('chat.send', { text, photos: S.staged.map((p) => ({ name: p.name, data: p.data })) }, 120000);
      input.value = '';
      store('vox.draft', null);
      grow(input);
      for (const p of S.staged) URL.revokeObjectURL(p.url);
      S.staged = [];
      drawStaged();
      scrollChat(false);
    } catch (e) {
      toast(e.message);
    } finally {
      S.sending = false;
      const b = $('#send');
      if (b) b.disabled = S.chat.busy;
    }
  }

  function sheet(title, build, opts) {
    const close = () => veil.remove();
    const body = h('div.sheet', { role: 'dialog', 'aria-modal': 'true', 'aria-label': title }, h('div.grab'));
    if (title) body.append(h('h2', { text: title }));
    const veil = h('div.veil', { onclick: (e) => e.target === veil && !(opts && opts.sticky) && close() }, body);
    build(body, close);
    document.body.append(veil);
    const first = body.querySelector('button, textarea, input');
    if (first) first.focus({ preventScroll: true });
    return { close, el: veil };
  }

  function companionSheet() {
    const st = S.state;
    if (st.companions.length < 2) return;
    sheet('Companions', (body, close) => {
      body.append(h('p', { text: 'Switching here switches your PC too.' }));
      const list = h('div.list');
      for (const c of st.companions) {
        list.append(
          h(
            'button.item' + (c.current ? '.on' : ''),
            {
              type: 'button',
              disabled: S.chat.busy && !c.current,
              onclick: async () => {
                if (c.current) return close();
                try {
                  await call('companion', { id: c.id });
                  close();
                  S.day = null;
                  S.pics = null;
                  S.story = null;
                  S.voces = null;
                } catch (e) {
                  toast(e.message);
                }
              },
            },
            avatar(c, { accent: c.accent }),
            h('span.grow', null, h('b', { text: c.name }), h('span', { text: (c.traits || []).slice(0, 3).join(' · ') })),
            c.current ? h('span.tick', { text: '✓' }) : null,
          ),
        );
      }
      body.append(list);
      if (S.chat.busy) body.append(h('p.note', { text: S.state.companion.name + ' is replying; switch once that\'s done.', style: { marginTop: '10px' } }));
    });
  }

  async function daysSheet() {
    let days;
    try {
      days = (await call('chat.days')).days;
    } catch (e) {
      return toast(e.message);
    }
    const today = new Date();
    const iso = (d) => d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
    const todayIso = iso(today);
    sheet('Earlier days', (body, close) => {
      const list = h('div.list');
      list.append(h('button.item' + (S.day ? '' : '.on'), { type: 'button', onclick: () => { close(); backToToday(); } }, h('span.grow', null, h('b', { text: 'Today' }))));
      for (const d of days.slice().reverse()) {
        if (d === todayIso) continue;
        const label = new Date(d + 'T12:00').toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
        list.append(
          h(
            'button.item' + (S.day && S.day.day === d ? '.on' : ''),
            {
              type: 'button',
              onclick: async () => {
                try {
                  const r = await call('chat.day', { day: d });
                  S.day = { day: d, label, msgs: r.msgs };
                  close();
                  render();
                  const s = $('#chat-scroll');
                  if (s) s.scrollTop = 0;
                } catch (e) {
                  toast(e.message);
                }
              },
            },
            h('span.grow', null, h('b', { text: label })),
          ),
        );
      }
      if (days.length === 0) body.append(h('p', { text: 'No earlier days yet.' }));
      body.append(list);
    });
  }

  // ------------------------------------------------------- questions

  function showAsk(m) {
    const s = sheet(
      m.title,
      (body, close) => {
        body.append(h('div.body', { text: m.body }));
        const answer = (yes) => {
          call('answer', { ask: m.ask, yes }).catch(() => {});
          close();
          S.asks.delete(m.ask);
        };
        body.append(
          h(
            'div.actions',
            null,
            h('button.btn', { type: 'button', onclick: () => answer(false) }, 'Don\'t allow'),
            h('button.btn.go', { type: 'button', onclick: () => answer(true) }, m.yes || 'Allow'),
          ),
        );
      },
      { sticky: true },
    );
    S.asks.set(m.ask, s.el);
  }

  // ------------------------------------------------------- images

  async function loadPics() {
    try {
      const r = await call('pics');
      S.pics = r.pics;
    } catch (e) {
      S.pics = S.pics || [];
      toast(e.message);
    }
    if (S.tab === 'images' && !S.view) render();
  }

  function renderImages() {
    const header = h(
      'header.bar',
      null,
      h('h1', { text: 'Images' }),
      S.state.draw
        ? h('button.pill', { type: 'button', onclick: openDraw }, icon('brush'), 'Draw')
        : null,
    );
    const body = h('div.scroll');
    tuckOn(body, 'top');
    body.append(h('div#drawing-card'));
    if (S.pics == null) body.append(h('div.empty', null, h('div.spinner', { style: { margin: '0 auto' } })));
    else if (!S.pics.length) {
      body.append(h('div.empty', { text: 'No pictures yet. Pictures ' + S.state.companion.name + ' draws, and ones you draw here, show up here.' }));
    } else {
      body.append(h('div.grid', null, S.pics.map((p) => picTile(p.ref, { video: p.video }))));
    }
    requestAnimationFrame(renderDrawingCard);
    return h('section.screen', { 'aria-label': 'Images' }, header, body);
  }

  function renderDrawingCard() {
    const slot = $('#drawing-card');
    if (!slot) return;
    slot.textContent = '';
    const d = S.drawing;
    if (!d) return;
    const pct = Math.round((d.progress || 0) * 100);
    slot.append(
      h(
        'div.drawing-card',
        null,
        h('div.spinner'),
        h(
          'div.grow',
          null,
          h('div', { text: (d.mine ? 'Drawing your picture' : 'Drawing') + (d.status ? ' · ' + d.status : '') }),
          d.waiting ? h('div.note', { text: d.waiting + ' more waiting' }) : null,
          h('div.progress', null, h('div', { style: { width: pct + '%' } })),
        ),
        d.mine ? h('button.pill', { type: 'button', onclick: () => call('draw.cancel').catch((e) => toast(e.message)) }, 'Cancel') : null,
      ),
    );
  }

  async function openDraw() {
    S.view = 'draw';
    render();
    if (!S.drawOpts) {
      try {
        S.drawOpts = await call('draw.options');
      } catch (e) {
        toast(e.message);
        S.view = null;
      }
      render();
    }
  }

  /** What is typed into Draw; it stays while the page is open. */
  const draft = { ready: false, prompt: '', loras: {} };

  /** Starts [draft] from the PC's Draw panel as it was left. */
  function draftFrom(o) {
    if (draft.ready) return;
    draft.ready = true;
    draft.byModel = {};
    draft.shape = o.shape || 'square';
    draft.advanced = !!o.advanced;
    draft.model = o.model;
    draft.width = o.width || '';
    draft.height = o.height || '';
    draft.ratio = o.ratio || '';
    choicesFor(o, o.model);
  }

  /** The picked model's own numbers, LoRAs and negative prompt. */
  function choicesFor(o, id) {
    const c = draft.byModel[id] || (o.choices && o.choices[id]) || {};
    draft.steps = c.steps != null && c.steps !== '' ? String(c.steps) : '';
    draft.cfg = c.cfg != null && c.cfg !== '' ? String(c.cfg) : '';
    draft.seed = c.seed != null && c.seed !== '' ? String(c.seed) : '';
    draft.sampler = c.sampler || '';
    draft.scheduler = c.scheduler || '';
    draft.negative = c.negative || '';
    draft.loras = Object.assign({}, c.loras || {});
  }

  const snap = (v) => Math.min(2048, Math.max(256, Math.round(v / 64) * 64));

  function ratioIn(text) {
    const m = /^\s*(\d+(?:\.\d+)?)\s*(?:[:xX/×]|\s)\s*(\d+(?:\.\d+)?)\s*$/.exec(text || '');
    if (!m) return null;
    const w = parseFloat(m[1]), hh = parseFloat(m[2]);
    if (w <= 0 || hh <= 0 || w / hh > 8 || hh / w > 8) return null;
    return { w, h: hh };
  }

  /** The size the picture gets when nothing is typed, as on the PC. */
  function sizeFor(model) {
    const r = ratioIn(draft.ratio);
    if (!r) return model.sizes[draft.shape] || model.sizes.square;
    const area = model.base * model.base;
    const w = Math.sqrt((area * r.w) / r.h);
    return [snap(w), snap(area / w)];
  }

  function renderDraw() {
    const o = S.drawOpts;
    const header = h(
      'header.bar',
      null,
      h('button.icon-btn.plain', { type: 'button', 'aria-label': 'Back to Images', onclick: () => { S.view = null; render(); } }, icon('back')),
      h('h1', { text: 'Draw' }),
    );
    const screen = h('section.screen', { 'aria-label': 'Draw' }, header);
    if (!o) {
      screen.append(h('div.empty', null, h('div.spinner', { style: { margin: '0 auto' } })));
      return screen;
    }
    if (!o.ready) {
      screen.append(h('div.empty', { text: o.why }));
      return screen;
    }
    draftFrom(o);
    const modelOf = () => o.models.find((m) => m.id === draft.model) || o.models[0];

    // Fields keep [draft] up to date as they are typed in.
    const field = (tag, key, attrs) => {
      const el = h(tag, attrs);
      el.value = draft[key] == null ? '' : draft[key];
      el.addEventListener('input', () => (draft[key] = el.value));
      return el;
    };
    const prompt = field('textarea#draw-prompt', 'prompt', { rows: 4 });
    const negative = field('textarea#draw-negative', 'negative', { rows: 2, placeholder: 'blurry, text, extra fingers' });
    const setPlaceholder = () => {
      prompt.placeholder = modelOf().tags ? '1girl, silver hair, reading, cozy library' : 'A lighthouse at dusk, rain on the glass…';
    };
    setPlaceholder();

    const shapes = h('div.shapes');
    const shapeBtn = (id, label, w, hgt) => {
      const b = h(
        'button',
        {
          type: 'button',
          'aria-pressed': draft.shape === id ? 'true' : 'false',
          onclick: () => {
            draft.shape = id;
            // A shape of its own gives way to typed sizes and ratios.
            draft.ratio = '';
            if (draft.advanced) draft.width = draft.height = '';
            shapes.querySelectorAll('button').forEach((x) => x.setAttribute('aria-pressed', x === b ? 'true' : 'false'));
            fillAdvanced();
          },
        },
        h('i', { style: { width: w + 'px', height: hgt + 'px' } }),
        label,
      );
      return b;
    };
    shapes.append(shapeBtn('portrait', 'Portrait', 18, 26), shapeBtn('square', 'Square', 22, 22), shapeBtn('landscape', 'Landscape', 28, 18));

    // Advanced: the PC's Draw panel, one under the other.
    const adv = h('div.adv');
    const modelSel = h('select#draw-model', { 'aria-label': 'Model' }, o.models.map((m) => h('option', { value: m.id, text: m.name })));
    modelSel.value = modelOf().id;
    modelSel.addEventListener('change', () => {
      // What was set for the last model stays with it, as on the PC.
      draft.byModel[draft.model] = {
        steps: draft.steps, cfg: draft.cfg, seed: draft.seed, sampler: draft.sampler,
        scheduler: draft.scheduler, negative: draft.negative, loras: draft.loras,
      };
      draft.model = modelSel.value;
      choicesFor(o, draft.model);
      negative.value = draft.negative;
      setPlaceholder();
      fillAdvanced();
    });
    const num = (key, label, opts) => {
      const el = h('input', { type: 'text', inputmode: opts && opts.decimal ? 'decimal' : 'numeric', 'aria-label': label });
      el.addEventListener('input', () => {
        draft[key] = el.value;
        if (key === 'width' || key === 'height') follow(key);
      });
      if (opts && opts.size) {
        el.addEventListener('blur', () => {
          const v = parseInt(el.value, 10);
          draft[key] = el.value = v ? String(snap(v)) : '';
          follow(key);
        });
      }
      return { el, box: h('label.num', null, h('span', { text: label }), el) };
    };
    const width = num('width', 'Width', { size: true });
    const height = num('height', 'Height', { size: true });
    const ratio = num('ratio', 'Ratio');
    ratio.el.inputMode = 'text';
    ratio.el.placeholder = '9:16';
    ratio.el.addEventListener('blur', () => {
      const r = ratioIn(ratio.el.value);
      draft.ratio = ratio.el.value = r ? r.w + ':' + r.h : '';
      follow('width');
      fillAdvanced();
    });
    const steps = num('steps', 'Steps');
    const cfg = num('cfg', 'Guidance', { decimal: true });
    const seed = num('seed', 'Seed');
    seed.el.placeholder = 'random';
    // With a ratio, typing one side works out the other.
    function follow(key) {
      const r = ratioIn(draft.ratio);
      if (!r) return;
      const w = parseInt(draft.width, 10), hh = parseInt(draft.height, 10);
      if (key === 'width' && w) draft.height = height.el.value = String(snap((w * r.h) / r.w));
      else if (key === 'height' && hh) draft.width = width.el.value = String(snap((hh * r.w) / r.h));
    }
    const swap = h('button.icon-btn', {
      type: 'button',
      'aria-label': 'Swap width and height',
      onclick: () => {
        const size = sizeFor(modelOf());
        const w = draft.width || String(size[0]);
        draft.width = draft.height || String(size[1]);
        draft.height = w;
        const r = ratioIn(draft.ratio);
        if (r) draft.ratio = r.h + ':' + r.w;
        fillAdvanced();
      },
    }, '⇄');
    const pickFrom = (id, label, list) => {
      const el = h('select', { id, 'aria-label': label });
      return { el, box: h('label.num.wide', null, h('span', { text: label }), el), list };
    };
    const sampler = pickFrom('draw-sampler', 'Sampler', o.samplers);
    const scheduler = pickFrom('draw-scheduler', 'Scheduler', o.schedulers);
    sampler.el.addEventListener('change', () => (draft.sampler = sampler.el.value));
    scheduler.el.addEventListener('change', () => (draft.scheduler = scheduler.el.value));
    const loras = h('div.loras');
    const reset = h('button.pill', {
      type: 'button',
      onclick: () => {
        Object.assign(draft, { width: '', height: '', ratio: '', steps: '', cfg: '', seed: '', sampler: '', scheduler: '' });
        fillAdvanced();
      },
    }, 'Back to the model\'s own');

    /** Puts [draft] and the model's own values into the advanced fields. */
    function fillAdvanced() {
      const m = modelOf();
      const size = sizeFor(m);
      width.el.value = draft.width || '';
      width.el.placeholder = String(size[0]);
      height.el.value = draft.height || '';
      height.el.placeholder = String(size[1]);
      ratio.el.value = draft.ratio || '';
      steps.el.value = draft.steps || '';
      steps.el.placeholder = String(m.steps);
      cfg.el.value = draft.cfg || '';
      cfg.el.placeholder = String(m.cfg);
      seed.el.value = draft.seed || '';
      for (const [pick, own] of [[sampler, m.sampler], [scheduler, m.scheduler]]) {
        pick.el.textContent = '';
        pick.el.append(h('option', { value: '', text: 'Model\'s own (' + own + ')' }));
        for (const [id, label] of pick.list) pick.el.append(h('option', { value: id, text: label }));
        pick.el.value = draft[pick === sampler ? 'sampler' : 'scheduler'] || '';
      }
      drawLoras();
    }

    let allLoras = false;
    function drawLoras() {
      loras.textContent = '';
      if (!o.loras.length) return;
      const picked = o.loras.filter((l) => l.name in draft.loras);
      const shown = allLoras || !picked.length ? o.loras : picked;
      loras.append(h('div.note', { text: 'LoRAs' + (picked.length ? ' · ' + picked.length + ' picked' : ''), style: { margin: '2px 0 6px' } }));
      for (const l of shown) {
        const on = l.name in draft.loras;
        const value = on ? draft.loras[l.name] : 0.8;
        const out = h('output', { text: value.toFixed(2) });
        const slider = h('input', { type: 'range', min: '-1', max: '2', step: '0.05', 'aria-label': l.name + ' strength', disabled: !on });
        slider.value = value;
        slider.addEventListener('input', () => {
          draft.loras[l.name] = parseFloat(slider.value);
          out.textContent = parseFloat(slider.value).toFixed(2);
        });
        loras.append(
          h(
            'div.lora' + (on ? '.on' : ''),
            null,
            h(
              'button.lora-name',
              {
                type: 'button',
                'aria-pressed': on ? 'true' : 'false',
                onclick: () => {
                  if (on) delete draft.loras[l.name];
                  else draft.loras[l.name] = 0.8;
                  drawLoras();
                },
              },
              h('b', { text: l.name }),
              l.note ? h('span', { text: l.note }) : null,
            ),
            on ? h('div.lora-weight', null, slider, out) : null,
          ),
        );
      }
      if (picked.length && picked.length < o.loras.length) {
        loras.append(
          h('button.pill', { type: 'button', style: { marginTop: '6px' }, onclick: () => { allLoras = !allLoras; drawLoras(); } }, allLoras ? 'Only the picked ones' : 'Show all ' + o.loras.length),
        );
      }
    }

    adv.append(
      h('label.field', null, 'Model', modelSel),
      h('div.nums', null, width.box, swap, height.box, ratio.box),
      h('div.nums', null, steps.box, cfg.box, seed.box),
      h('div.nums', null, sampler.box, scheduler.box),
      h('div', null, reset),
      loras,
    );
    fillAdvanced();

    const advSwitch = h('button.switch', {
      type: 'button',
      role: 'switch',
      'aria-checked': draft.advanced ? 'true' : 'false',
      'aria-label': 'Advanced',
      onclick: () => {
        draft.advanced = !draft.advanced;
        advSwitch.setAttribute('aria-checked', draft.advanced ? 'true' : 'false');
        adv.hidden = !draft.advanced;
        modelLine.hidden = draft.advanced;
      },
    }, h('i'));
    adv.hidden = !draft.advanced;
    const modelLine = h('p.note', { text: 'Uses ' + modelOf().name + ' and the settings from your PC. The picture lands in Images.' });
    modelLine.hidden = draft.advanced;

    const form = h(
      'div.form',
      null,
      h('div.row-between', null, h('span', { text: 'What to draw', class: 'label' }), h('label.toggle', null, 'Advanced', advSwitch)),
      prompt,
      o.presets.length
        ? h(
            'div',
            null,
            h('div.note', { text: 'Presets from your PC', style: { marginBottom: '6px' } }),
            h(
              'div.chips',
              null,
              o.presets.map((p) =>
                h('button.pill', { type: 'button', onclick: () => { draft.prompt = prompt.value = p.prompt; draft.negative = negative.value = p.negative || ''; } }, p.name),
              ),
            ),
          )
        : null,
      h('label.field', null, 'Leave out (optional)', negative),
      adv,
      h('div', null, h('div.note', { text: 'Shape', style: { marginBottom: '6px' } }), shapes),
      h('button.btn.go.wide', {
        type: 'button',
        onclick: async (e) => {
          if (!draft.prompt.trim()) return toast('Say what to draw first.');
          e.target.disabled = true;
          const ask = { prompt: draft.prompt, negative: draft.negative, shape: draft.shape, advanced: !!draft.advanced };
          if (draft.advanced) {
            Object.assign(ask, {
              model: draft.model,
              width: draft.width,
              height: draft.height,
              ratio: draft.ratio,
              steps: draft.steps,
              cfg: draft.cfg,
              seed: draft.seed,
              sampler: draft.sampler || null,
              scheduler: draft.scheduler || null,
              loras: draft.loras,
            });
          }
          try {
            await call('draw', ask);
            // The PC keeps these now; ask again next time.
            S.drawOpts = null;
            draft.ready = false;
            const kept = draft.prompt;
            S.view = null;
            draft.prompt = kept;
            render();
            toast('Drawing on your PC…');
          } catch (err) {
            toast(err.message);
            e.target.disabled = false;
          }
        },
      }, 'Draw'),
      modelLine,
    );
    screen.append(h('div.scroll', null, form));
    return screen;
  }

  // ------------------------------------------------------- Voces Mundi

  function artStyle(art, picRef, el) {
    const cols = (art && art.colors) || ['#8a6bd6', '#3a2a5a', '#1a1030'];
    el.style.backgroundImage = 'linear-gradient(' + ((art && art.angle) || 135) + 'deg, ' + cols.join(', ') + ')';
    if (picRef) {
      picture(picRef, false).then((p) => (el.style.backgroundImage = 'url("' + p.url + '")'), () => {});
    }
    return el;
  }

  function personAv(p, size) {
    const el = h('span.av', { style: size ? { width: size + 'px', height: size + 'px' } : null, title: p.name, 'aria-hidden': 'true' });
    artStyle(p.art, p.picture, el);
    if (!p.picture) el.textContent = (p.name || '?').trim().charAt(0).toUpperCase();
    return el;
  }

  async function loadVoces() {
    try {
      S.voces = await call('voces');
    } catch (e) {
      S.voces = { stories: [], worlds: [], error: e.message };
    }
    if (S.tab === 'voces' && !S.story) render();
  }

  function renderVoces() {
    const header = h('header.bar', null, h('h1', { text: 'Voces Mundi' }));
    const body = h('div.scroll');
    tuckOn(body, 'top');
    const v = S.voces;
    if (!v) {
      body.append(h('div.empty', null, h('div.spinner', { style: { margin: '0 auto' } })));
    } else if (v.error) {
      body.append(h('div.empty', { text: v.error }));
    } else {
      const cards = h('div.cards');
      if (v.stories.length) {
        cards.append(h('h3', { text: 'Carry on' }));
        for (const s of v.stories.slice(0, 12)) {
          const card = h(
            'button.card',
            { type: 'button', onclick: () => openStory(s.id) },
            h('b', { text: s.title }),
            h('span', { text: s.player + ' in ' + s.world + (s.place ? ' · ' + s.place : '') }),
            h('span', { text: s.turns + ' turns · ' + when(s.at) }),
          );
          cards.append(artStyle(s.art, s.picture, card));
        }
      }
      cards.append(h('h3', { text: 'Start a story' }));
      if (!v.worlds.length) cards.append(h('div.empty', { text: 'No worlds yet. Make one in Voces Mundi on your PC.' }));
      for (const w of v.worlds) {
        const card = h(
          'button.card',
          { type: 'button', onclick: () => newStory(w.id) },
          w.adult ? h('span.badge', { text: '18+' }) : null,
          h('b', { text: w.name }),
          h('span', { text: w.line }),
          h('div.tags', null, w.tags.map((t) => h('em', { text: t })), h('em', { text: w.cast + ' people' })),
        );
        cards.append(artStyle(w.art, w.picture, card));
      }
      cards.append(h('p.note', { text: 'Make and change worlds and characters in Voces Mundi on your PC.', style: { textAlign: 'center' } }));
      body.append(cards);
    }
    return h('section.screen', { 'aria-label': 'Voces Mundi' }, header, body);
  }

  async function newStory(worldId) {
    let info;
    try {
      info = await call('voces.new', { world: worldId });
    } catch (e) {
      return toast(e.message);
    }
    const pick = { player: info.player, cast: new Set(info.cast), opening: info.openings[0] || null, difficulty: 'neutral', title: '' };
    if (!info.difficulties.some((d) => d.id === 'neutral') && info.difficulties[0]) pick.difficulty = info.difficulties[0].id;
    sheet('A new story in ' + info.world.name, (body, close) => {
      const draw = () => {
        body.querySelectorAll('.part').forEach((x) => x.remove());
        const part = h('div.part');
        part.append(h('div.note', { text: 'You play', style: { margin: '6px 0' } }));
        part.append(
          h(
            'div.chips',
            null,
            info.characters.map((c) =>
              h('button.pill' + (pick.player === c.id ? '.on' : ''), { type: 'button', onclick: () => { pick.player = c.id; pick.cast.delete(c.id); draw(); } }, personAv(c, 20), c.name),
            ),
          ),
        );
        const castable = info.characters.filter((c) => info.castIds.includes(c.id) && c.id !== pick.player);
        if (castable.length) {
          part.append(h('div.note', { text: 'Who is there at the start', style: { margin: '14px 0 6px' } }));
          part.append(
            h(
              'div.chips',
              null,
              castable.map((c) =>
                h('button.pill' + (pick.cast.has(c.id) ? '.on' : ''), { type: 'button', onclick: () => { pick.cast.has(c.id) ? pick.cast.delete(c.id) : pick.cast.add(c.id); draw(); } }, personAv(c, 20), c.name),
              ),
            ),
          );
        }
        if (info.openings.length > 1) {
          part.append(h('div.note', { text: 'How it begins', style: { margin: '14px 0 6px' } }));
          part.append(
            h('div.list', null, info.openings.map((o) => h('button.item' + (pick.opening === o ? '.on' : ''), { type: 'button', onclick: () => { pick.opening = o; draw(); } }, h('span.grow', null, h('b', { text: o }))))),
          );
        }
        part.append(h('div.note', { text: 'How hard', style: { margin: '14px 0 6px' } }));
        part.append(h('div.seg', null, info.difficulties.map((d) => h('button', { type: 'button', 'aria-pressed': pick.difficulty === d.id ? 'true' : 'false', onclick: () => { pick.difficulty = d.id; draw(); } }, d.label))));
        const chosen = info.difficulties.find((d) => d.id === pick.difficulty);
        if (chosen) part.append(h('p.note', { text: chosen.blurb, style: { margin: '6px 0 0' } }));
        const title = h('input', { type: 'text', placeholder: 'Title (optional)', style: { marginTop: '14px', width: '100%', borderRadius: '14px', border: '1px solid var(--line)', background: 'var(--faint)', padding: '12px', fontSize: '16px' } });
        title.value = pick.title;
        title.addEventListener('input', () => (pick.title = title.value));
        part.append(title);
        part.append(
          h(
            'div.actions',
            { style: { marginTop: '16px' } },
            h('button.btn', { type: 'button', onclick: close }, 'Cancel'),
            h('button.btn.go', {
              type: 'button',
              disabled: !pick.player,
              onclick: async (e) => {
                e.target.disabled = true;
                try {
                  const r = await call('voces.start', { world: worldId, player: pick.player, cast: [...pick.cast], opening: pick.opening, difficulty: pick.difficulty, title: pick.title }, 120000);
                  close();
                  S.story = { id: r.story.id };
                  storyEvent(r.story, true);
                } catch (err) {
                  toast(err.message);
                  e.target.disabled = false;
                }
              },
            }, 'Start'),
          ),
        );
        body.append(part);
      };
      draw();
    });
  }

  async function openStory(id) {
    try {
      const r = await call('voces.open', { story: id }, 120000);
      S.story = { id };
      storyEvent(r.story, true);
    } catch (e) {
      toast(e.message);
    }
  }

  function closeStory() {
    call('voces.close').catch(() => {});
    S.story = null;
    turnEls.clear();
    loadVoces();
    render();
  }

  function storyEvent(m, fresh) {
    if (!m) return;
    const st = fresh ? { turns: new Map() } : S.story;
    if (!st) return;
    st.turns = st.turns || new Map();
    for (const t of m.turns || []) st.turns.set(t.id, t);
    for (const k in m) if (k !== 'turns') st[k] = m[k];
    for (const id of [...st.turns.keys()]) if (!st.order.includes(id)) st.turns.delete(id);
    S.story = st;
    if (S.tab !== 'voces') return;
    if (fresh || !$('#story-list')) {
      turnEls.clear();
      render();
    } else updateStory();
  }

  const turnEls = new Map();

  function renderStory() {
    const s = S.story;
    const cast = (s.cast || []).filter((p) => p.here && !p.you);
    const header = h(
      'header.bar',
      null,
      h('button.icon-btn.plain', { type: 'button', 'aria-label': 'Back to Voces Mundi', onclick: closeStory }, icon('back')),
      h('span.titles', null, h('b', { text: s.title || '' }), h('span#story-place', { text: s.place || s.world || '' })),
      h('button.cast-btn', { type: 'button', 'aria-label': 'Who is here', onclick: castSheet }, cast.slice(0, 3).map((p) => personAv(p, 26)), icon('down', 16)),
    );
    const list = h('div.story#story-list');
    const scroller = h('div.scroll#story-scroll', null, list);
    stick(scroller, list);
    const screen = h('section.screen', { 'aria-label': s.title || 'Story' }, header, scroller, h('div#story-recap'), renderStoryComposer());
    requestAnimationFrame(() => {
      updateStory(true);
      scrollChat(true);
    });
    return screen;
  }

  function turnEl(t, s) {
    const roll = t.roll ? h('span.roll', { text: '🎲 ' + t.roll.n + ' · ' + t.roll.outcome }) : null;
    switch (t.kind) {
      case 'scene':
        return h('div.divider', { text: t.text });
      case 'picture':
        return t.picture ? picTile(t.picture, { label: 'Scene picture' }) : h('div.note', { text: 'This picture is missing.' });
      case 'narrator':
        return h('div.narr', { html: marked(t.text).replace(/\n/g, '<br>') });
      case 'character': {
        const p = (s.cast || []).find((c) => c.id === t.speakerId) || { name: t.speaker };
        return h('div.turn-who', null, personAv(p), h('div.say', null, h('span.nm', { text: t.speaker }), h('span', { html: marked(t.text).replace(/\n/g, '<br>') })));
      }
      default: {
        const label = t.kind === 'act' ? s.player + ' does' : t.kind === 'ask' ? 'You ask the narrator' : s.player;
        return h(
          'div.mine.' + t.kind,
          null,
          h('span.nm', { text: label }),
          roll,
          h('span.txt', { html: (t.kind === 'say' ? marked(t.text) : esc(t.text)).replace(/\n/g, '<br>') }),
        );
      }
    }
  }

  function updateStory(fresh) {
    const list = $('#story-list');
    const s = S.story;
    if (!list || !s) return;
    const scroller = $('#story-scroll');
    const nearEnd = !scroller || scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 160;
    if (fresh) {
      turnEls.clear();
      list.textContent = '';
    }
    if (!s.ready && !(s.order || []).length) {
      list.textContent = '';
      list.append(h('div.empty', null, h('div.spinner', { style: { margin: '0 auto' } })));
      return;
    }
    const wanted = [];
    for (const id of s.order || []) {
      const t = s.turns.get(id);
      if (!t) continue;
      const sig = JSON.stringify([t.text, t.kind, t.speaker, t.picture, t.roll]);
      let entry = turnEls.get(id);
      if (!entry || entry.sig !== sig) {
        const el = turnEl(t, s);
        if (entry) entry.el.replaceWith(el);
        entry = { el, sig };
        turnEls.set(id, entry);
      }
      wanted.push(entry.el);
    }
    for (const [id, entry] of turnEls) {
      if (!(s.order || []).includes(id)) {
        entry.el.remove();
        turnEls.delete(id);
      }
    }
    // What is being written now.
    if (s.writing) {
      const w = s.writing;
      const live = w.who
        ? h('div.turn-who', null, personAv((s.cast || []).find((c) => c.id === w.who) || { name: w.name || '?' }), h('div.say', null, h('span.nm', { text: w.name || '' }), h('span', { html: marked(w.text).replace(/\n/g, '<br>') }), h('span.caret')))
        : h('div.narr', { html: marked(w.text).replace(/\n/g, '<br>') }, h('span.caret'));
      wanted.push(live);
    } else if (s.busy) {
      wanted.push(h('div.note', { text: (s.writer || 'The narrator') + ' is writing…' }));
    }
    if (s.error) wanted.push(h('div.error', { text: s.error }));
    list.textContent = '';
    for (const el of wanted) list.append(el);
    const place = $('#story-place');
    if (place) place.textContent = s.place || s.world || '';
    const recap = $('#story-recap');
    if (recap) {
      recap.textContent = '';
      if (s.recap || s.recapping) {
        recap.append(
          h(
            'div.recap',
            null,
            h('b', { text: 'So far' }),
            h('div', { text: s.recapping && !s.recap ? 'Writing a recap…' : s.recap }),
            s.recap ? h('div', { style: { textAlign: 'right' } }, h('button.pill', { type: 'button', onclick: () => storyOp('closeRecap') }, 'Close')) : null,
          ),
        );
      }
    }
    const state = $('#story-state');
    if (state) state.replaceWith(storyState());
    if (nearEnd) scrollChat(false);
  }

  function storyOp(op, args) {
    return call('story.' + op, args).catch((e) => toast(e.message));
  }

  function storyState() {
    const s = S.story;
    const row = h('div.center-row#story-state');
    if (s.busy) {
      row.append(h('button.pill', { type: 'button', onclick: () => storyOp('stop') }, icon('stop'), 'Stop'));
      if (s.chain > 0) {
        row.append(h('button.pill' + (s.jumpedIn ? '.on' : ''), { type: 'button', onclick: () => storyOp('jumpIn') }, s.jumpedIn ? 'Your turn next' : 'Jump in'));
      }
    } else if (s.canRetry) {
      row.append(h('button.pill', { type: 'button', onclick: () => storyOp('retry') }, icon('retry'), 'Try again'));
    }
    if (s.drawing) row.append(h('span.note', { text: 'Drawing the scene…' }));
    return row;
  }

  const MODES = [
    ['say', 'Say', 'What do you say?'],
    ['act', 'Do', 'What do you do?'],
    ['ask', 'Ask the narrator', 'Ask for something: “let night fall”'],
  ];

  function renderStoryComposer() {
    const mode = MODES.find((m) => m[0] === S.storyMode) || MODES[0];
    const input = h('textarea#story-input', { rows: 1, placeholder: mode[2], 'aria-label': mode[1], enterkeyhint: 'send', oninput: () => { grow(input); if (S.story.busy && !S.story.jumpedIn && S.story.chain > 0) storyOp('jumpIn'); } });
    input.value = store('vox.storyDraft') || '';
    input.addEventListener('input', () => store('vox.storyDraft', input.value));
    const modes = h(
      'div.modes',
      null,
      MODES.map((m) =>
        h('button.pill' + (S.storyMode === m[0] ? '.on' : ''), { type: 'button', 'aria-pressed': S.storyMode === m[0] ? 'true' : 'false', onclick: () => { S.storyMode = m[0]; const v = input.value; render(); const i = $('#story-input'); if (i) { i.value = v; } } }, m[1]),
      ),
      S.storyMode !== 'ask'
        ? h('button.pill' + (S.roll ? '.on' : ''), { type: 'button', 'aria-pressed': S.roll ? 'true' : 'false', 'aria-label': 'Roll the dice for this turn', title: 'Roll for this turn: a lie, a sneak, a leap', onclick: () => { S.roll = !S.roll; const v = input.value; render(); const i = $('#story-input'); if (i) i.value = v; } }, icon('dice'))
        : null,
    );
    const go = async () => {
      const text = input.value.trim();
      const s = S.story;
      if (!text || !s || s.busy) return;
      try {
        await call('story.send', { kind: S.storyMode, text, roll: S.roll && S.storyMode !== 'ask' });
        input.value = '';
        store('vox.storyDraft', null);
        S.roll = false;
        grow(input);
      } catch (e) {
        toast(e.message);
      }
    };
    requestAnimationFrame(() => grow(input));
    return h(
      'div.composer',
      null,
      storyState(),
      modes,
      h(
        'div.row',
        null,
        input,
        h('button.round-btn.soft', { type: 'button', 'aria-label': 'Let the story go on', title: 'Let the story go on', onclick: () => storyOp('continue') }, icon('forward')),
        h('button.round-btn.go', { type: 'button', 'aria-label': 'Send', onclick: go }, icon('send')),
      ),
    );
  }

  function castSheet() {
    const s = S.story;
    sheet('Who is here', (body, close) => {
      const draw = () => {
        body.querySelectorAll('.part').forEach((x) => x.remove());
        const st = S.story;
        const part = h('div.part');
        const here = (st.cast || []).filter((p) => p.here);
        const away = (st.cast || []).filter((p) => !p.here);
        const list = h('div.list');
        for (const p of here) {
          list.append(
            h(
              'div.item',
              null,
              personAv(p, 36),
              h('span.grow', null, h('b', { text: p.name }), h('span', { text: p.you ? 'You' : p.pinned ? 'Pinned: stays here' : 'Here' })),
              p.you
                ? null
                : h('button.pill' + (p.pinned ? '.on' : ''), { type: 'button', 'aria-label': (p.pinned ? 'Unpin ' : 'Pin ') + p.name, onclick: async () => { await storyOp('pin', { id: p.id, on: !p.pinned }); p.pinned = !p.pinned; draw(); } }, icon('pin')),
              p.you ? null : h('button.pill', { type: 'button', disabled: st.busy, onclick: async () => { await storyOp('sendAway', { id: p.id }); close(); } }, 'Send away'),
            ),
          );
        }
        part.append(list);
        if (away.length) {
          part.append(h('div.note', { text: 'Not here', style: { margin: '12px 0 4px' } }));
          const l2 = h('div.list');
          for (const p of away) {
            l2.append(
              h(
                'div.item',
                null,
                personAv(p, 36),
                h('span.grow', null, h('b', { text: p.name })),
                h('button.pill', { type: 'button', disabled: st.busy, onclick: async () => { await storyOp('bringIn', { id: p.id }); close(); } }, icon('plus', 14), 'Bring in'),
              ),
            );
          }
          part.append(l2);
        }
        part.append(h('div.note', { text: 'Comings and goings', style: { margin: '16px 0 6px' } }));
        part.append(
          h(
            'div.seg',
            null,
            [['calm', 'Calm'], ['normal', 'Normal'], ['busy', 'Busy']].map(([id, label]) =>
              h('button', { type: 'button', 'aria-pressed': st.liveliness === id ? 'true' : 'false', onclick: async () => { await storyOp('liveliness', { value: id }); st.liveliness = id; draw(); } }, label),
            ),
          ),
        );
        part.append(h('div.note', { text: 'Replies in a row', style: { margin: '14px 0 6px' } }));
        part.append(
          h(
            'div.seg',
            null,
            [0, 1, 2, 3, 4].map((n) =>
              h('button', { type: 'button', 'aria-pressed': st.chain === n ? 'true' : 'false', onclick: async () => { await storyOp('chain', { value: n }); st.chain = n; draw(); } }, n === 0 ? 'Off' : String(n)),
            ),
          ),
        );
        part.append(
          h(
            'div.actions',
            { style: { marginTop: '18px', justifyContent: 'stretch' } },
            h('button.btn', { type: 'button', style: { flex: '1' }, disabled: st.recapping, onclick: () => { storyOp('recap'); close(); } }, 'Recap so far'),
            S.state.draw ? h('button.btn', { type: 'button', style: { flex: '1' }, disabled: st.drawing, onclick: () => { storyOp('drawScene'); close(); toast('Drawing the scene on your PC…'); } }, 'Draw the scene') : null,
          ),
        );
        body.append(part);
      };
      draw();
    });
    return s;
  }

  // ------------------------------------------------------- start

  // A QR code's way in, read once and taken out of the address.
  let sessionPair = null;
  function readPairing(hash) {
    const m = /pair=([\w-]+)\.([\w-]+)/.exec(hash || location.hash);
    if (!m) return false;
    try {
      sessionPair = { id: m[1], secret: unb64(m[2]) };
    } catch (e) {
      sessionPair = null;
    }
    if (!hash) history.replaceState(null, '', location.pathname);
    if (sessionPair) store('vox.device', null);
    return !!sessionPair;
  }
  readPairing();
  // A code opened in this tab while the page is already up.
  window.addEventListener('hashchange', () => {
    if (readPairing()) startPairing();
  });
  function startPairing() {
    link.tries = 0;
    S.check = null;
    S.phase = 'start';
    S.why = '';
    if (link.ws) {
      const old = link.ws;
      link.ws = null;
      old.close();
    }
    render();
    connect();
  }

  window.matchMedia('(prefers-color-scheme: light)').addEventListener('change', () => S.state && applyLook(S.state.look));
  document.addEventListener('visibilitychange', () => {
    // Phones drop connections in the background; come back at once.
    if (document.visibilityState === 'visible' && (!link.ws || link.ws.readyState > 1) && (store('vox.device') || sessionPair)) {
      link.tries = 0;
      connect();
    }
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      const v = $('.viewer') || $('.veil');
      if (v && !(v.classList.contains('veil') && $('.sheet .actions .btn.go', v) && S.asks.size)) v.remove();
    }
    if (e.key === 'Enter' && !e.shiftKey && window.matchMedia('(pointer: fine)').matches) {
      if (e.target.id === 'chat-input') {
        e.preventDefault();
        sendChat(e.target);
      } else if (e.target.id === 'story-input') {
        e.preventDefault();
        const b = e.target.parentElement.querySelector('.round-btn.go');
        if (b) b.click();
      }
    }
  });

  render();
  connect();
})();
