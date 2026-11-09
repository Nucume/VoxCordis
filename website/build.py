"""Builds the VoxCordis website as one page: the welcome (heart, name, download) under a glass header it folds into,
   a short chat with Voxette, the app window to click around in, privacy, download, questions, and the footer.
   Fireflies drift behind all of it (src/flow.js).
   python3 website/build.py          -> website/out/: index.html, favicon.svg and fonts/, for GitHub Pages
   python3 website/build.py --frag   -> website/out/index.html only, as a fragment (for a mockup host that adds the skeleton)
   Plain Python 3, no packages. The pages workflow of the public repository runs it and puts out/ on gh-pages."""
import sys, os, re, shutil, json
HERE = os.path.dirname(os.path.abspath(__file__))
FULL = '--frag' not in sys.argv
SRC, OUT = os.path.join(HERE, 'src'), os.path.join(HERE, 'out')
rd = lambda f: open(os.path.join(SRC, f), encoding='utf-8').read()
os.makedirs(OUT, exist_ok=True)

DISCORD = 'https://discord.gg/hJCzp7tVaT'
X = 'https://x.com/VoxCordisAI'
REDDIT = 'https://www.reddit.com/r/VoxCordis/'
GH = 'https://github.com/Nucume/VoxCordis'
MINI = '<svg class="logo" viewBox="110 125 780 750" aria-hidden="true"><g class="mini"><use href="#vc-lines" style="stroke:var(--vs,url(#vc-g));fill:var(--vs,url(#vc-g))"/><use href="#vc-lines" style="stroke:var(--vd,url(#vc-d));fill:var(--vd,url(#vc-d))"/></g></svg>'
SPRITE = f'<svg width="0" height="0" style="position:absolute" aria-hidden="true">{rd("defs.svgfrag")}</svg>'
I = {
 'discord': '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" fill-rule="evenodd" d="M19.5 5.5A16 16 0 0 0 15.6 4.3l-.5 1a15 15 0 0 0-6.2 0l-.5-1a16 16 0 0 0-3.9 1.2C2 9.2 1.4 12.8 1.7 16.4a16 16 0 0 0 4.8 2.4l1-1.6a10 10 0 0 1-1.6-.8l.4-.3a11.5 11.5 0 0 0 11.4 0l.4.3a10 10 0 0 1-1.6.8l1 1.6a16 16 0 0 0 4.8-2.4c.4-4.2-.6-7.8-2.9-10.9zM8.7 14.2c-1 0-1.8-.9-1.8-2s.8-2 1.8-2 1.8.9 1.8 2-.8 2-1.8 2zm6.6 0c-1 0-1.8-.9-1.8-2s.8-2 1.8-2 1.8.9 1.8 2-.8 2-1.8 2z"/></svg>',
 'x': '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/></svg>',
 'reddit': '<svg viewBox="0 0 24 24" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><ellipse cx="12" cy="14.6" rx="8" ry="5.6"/><path d="M12 9l1.4-4.6 4.1 1"/><circle cx="19" cy="5.4" r="1.5"/><path d="M6 10.4a1.9 1.9 0 1 0-1.9 2.4M18 10.4a1.9 1.9 0 1 1 1.9 2.4"/><path d="M9 17.2c1.8 1 4.2 1 6 0"/></g><circle cx="9" cy="13.8" r="1.3" fill="currentColor"/><circle cx="15" cy="13.8" r="1.3" fill="currentColor"/></svg>',
 'github': '<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="currentColor" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>',
 'win': '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M3 5.5 10.5 4.4v7H3zm0 13L10.5 19.6v-7H3zm8.5 1.2L21 21v-8.4h-9.5zm0-15.4L21 3v8.4h-9.5z"/></svg>',
 'linux': '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M12 2.5c-2.6 0-3.6 2.4-3.4 5 .1 1.5-.4 2.5-1.6 4.2C5.6 13.6 4.6 16 5.6 18c-1 .5-1.8 1.4-1 2.2.9.9 3 .3 4.2 1 1.2.7 2.2.4 3.2-.5 1 .9 2 1.2 3.2.5 1.2-.7 3.3-.1 4.2-1 .8-.8 0-1.7-1-2.2 1-2-0-4.4-1.4-6.3-1.2-1.7-1.7-2.7-1.6-4.2.2-2.6-.8-5-3.4-5z"/><circle cx="10.4" cy="7" r=".9" fill="currentColor"/><circle cx="13.6" cy="7" r=".9" fill="currentColor"/></svg>',
 'dl': '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" d="M12 4v11m-5-5 5 5 5-5M5 20h14"/></svg>',
 'lock': '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="10.5" width="14" height="10" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" fill="none" stroke="currentColor" stroke-width="1.8"/></svg>',
 'spark': '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M11 3l1.7 4.8L17.5 9.5l-4.8 1.7L11 16l-1.7-4.8L4.5 9.5l4.8-1.7zM18.5 14l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z"/></svg>',
 'file': '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M6 3h8l4 4v14H6zM14 3v4h4M9 12h6M9 16h6"/></svg>',
 'clock': '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="13" r="8" fill="none" stroke="currentColor" stroke-width="1.8"/><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M12 9v4l2.5 2"/></svg>',
 'cap': '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="m2 9 10-5 10 5-10 5zM6 11v5c3 2 9 2 12 0v-5"/></svg>',
 'chip': '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6" y="6" width="12" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="1.8"/><path stroke="currentColor" stroke-width="1.8" stroke-linecap="round" d="M9 3v3m6-3v3M9 18v3m6-3v3M3 9h3m-3 6h3m12-6h3m-3 6h3"/></svg>',
}
NAV = [('#tour', 'Meet Voxette'), ('#voces', 'Voces Mundi'), ('#private', 'Privacy'), ('#download', 'Download'), ('#faq', 'FAQ')]
NAVLINKS = ''.join(f'<a href="{h}">{t}</a>' for h, t in NAV)
SOCIALS = ('<div class="socials">' + ''.join(f'<a href="{u}" aria-label="{n}" title="{n}">{I[k]}</a>' for n, u, k in
           [('Discord', DISCORD, 'discord'), ('X', X, 'x'), ('Reddit', REDDIT, 'reddit'), ('GitHub', GH, 'github')]) + '</div>')
# the theme and Colorway menu, top right: System / Light / Dark and the app's Colorways as orbs
CHEVRON = '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" d="m6 9 6 6 6-6"/></svg>'
LOOK = ('<div class="lookm"><button type="button" class="lookbtn" aria-haspopup="true" aria-expanded="false" aria-label="Theme and Colorway"><i class="orb" data-orb-now></i>' + CHEVRON + '</button>'
        '<div class="lookpop" hidden><p>Theme</p><div class="seg" data-themes role="group" aria-label="Theme"><button type="button" data-t="system">System</button><button type="button" data-t="light">Light</button><button type="button" data-t="dark">Dark</button></div>'
        '<p>Colorway</p><div class="ways" data-ways role="group" aria-label="Colorways"></div></div></div>')

def qa(q, a): return f'<details class="qa"><summary>{q}</summary><div><p>{a}</p></div></details>'

# ---------------------------------------------------------------- Voces Mundi: the story mode, "Voces Mundi, by VoxCordis"
# Its mark is a globe drawn in the heart's strands and nodes, with the heart's heartbeat line for its equator.
# Like the heart, it takes the Colorway's colours (--k1..--k4, deepened on the light theme by base.css).
VM_DEFS = ('<defs><linearGradient id="vm-g" gradientUnits="userSpaceOnUse" x1="38" y1="0" x2="162" y2="0"><stop offset="0" style="stop-color:var(--k1)"/><stop offset=".38" style="stop-color:var(--k2)"/><stop offset=".64" style="stop-color:var(--k3)"/><stop offset="1" style="stop-color:var(--k4)"/></linearGradient>'
  '<radialGradient id="vm-h" cx="100" cy="100" r="76" gradientUnits="userSpaceOnUse"><stop offset="0" style="stop-color:var(--k2);stop-opacity:.3"/><stop offset="1" style="stop-color:var(--k3);stop-opacity:0"/></radialGradient>'
  '<filter id="vm-neon" x="-30%" y="-30%" width="160%" height="160%" color-interpolation-filters="sRGB"><feGaussianBlur in="SourceGraphic" stdDeviation="7" result="b2"/><feComponentTransfer in="b2" result="b2o"><feFuncA type="linear" slope=".85"/></feComponentTransfer>'
  '<feGaussianBlur in="SourceGraphic" stdDeviation="1.6" result="b1"/><feMorphology in="SourceGraphic" operator="erode" radius=".8" result="e"/><feColorMatrix in="e" type="matrix" values=".55 0 0 0 .45 0 .55 0 0 .45 0 0 .55 0 .45 0 0 0 .6 0"/><feGaussianBlur stdDeviation=".35" result="core"/>'
  '<feMerge><feMergeNode in="b2o"/><feMergeNode in="b1"/><feMergeNode in="SourceGraphic"/><feMergeNode in="core"/></feMerge></filter>'
  '<filter id="vm-soft" x="-30%" y="-30%" width="160%" height="160%" color-interpolation-filters="sRGB"><feGaussianBlur in="SourceGraphic" stdDeviation="3" result="b"/><feComponentTransfer in="b" result="bo"><feFuncA type="linear" slope=".35"/></feComponentTransfer><feMerge><feMergeNode in="bo"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>')
def globe(cls, bold=False, glow=True):
    """bold: for small sizes, thicker lines and no hairlines, like the heart's .logo."""
    w = (lambda x: f'{x * 2:.1f}') if bold else (lambda x: f'{x:g}')
    rings = '' if bold else '<path d="M46 69A54 8 0 0 0 154 69M46 131A54 8 0 0 0 154 131" stroke-width="2.2" opacity=".7"/>'
    nodes = [(100, 38, 5), (100, 162, 5), (38, 100, 4.6), (162, 100, 4.6)] + ([] if bold else [(78.4, 76, 3), (121.6, 76, 3), (78.4, 138.5, 3), (121.6, 138.5, 3), (171, 52, 2.2), (30, 152, 1.8)])
    return (f'<svg class="{cls}" viewBox="0 0 200 200" aria-hidden="true">' + ('<circle cx="100" cy="100" r="76" fill="url(#vm-h)"/>' if glow else '')
            + '<g' + (' filter="url(#vm-neon)"' if glow else '') + ' stroke="url(#vm-g)" fill="url(#vm-g)" stroke-linecap="round" stroke-linejoin="round"><g fill="none">'
            f'<circle cx="100" cy="100" r="62" stroke-width="{w(5.5)}"/><ellipse cx="100" cy="100" rx="26" ry="62" stroke-width="{w(2.8)}"/>{rings}'
            f'<path d="M38 100H72L79 100 85 88 92 116 100 60 108 136 115 92 121 100H162" stroke-width="{w(5)}"/></g>'
            + ''.join(f'<circle cx="{x}" cy="{y}" r="{r * (1.4 if bold else 1):g}"/>' for x, y, r in nodes) + '</g></svg>')
# Screenshots of the app (static/voces/), with an example library and story
VM_SHOTS = [
 ('library', 'The library', 'Your worlds, characters and lorebooks, with the story you were playing at the top.'),
 ('new-story', 'Starting a story', 'Pick who you play, how hard the world is, how it begins and who is there.'),
 ('story', 'A story in play', 'The narrator, the cast and you, with story notes and a dice roll for a risky move.'),
]
VOCES = f'''<section class="gutter vm" id="voces"><div class="w">
  <svg width="0" height="0" style="position:absolute" aria-hidden="true">{VM_DEFS}</svg>
  <div class="vm-mark">{globe('vmark')}<div class="vm-word" role="img" aria-label="Voces Mundi"><b>VOCES</b><span>MUNDI</span></div><div class="vm-by">by <b>VOX</b> CORDIS</div></div>
  <h2>Step inside the story</h2>
  <p class="lead">Voces Mundi is where your model becomes a narrator and a whole cast. Worlds come to life around the character you play, on your own computer, as privately as everything else.</p>
  <ol class="vm-steps">
    <li><i>1</i><b>Pick a world</b><span>Make one in a few lines, or bring a character card or lorebook. Your model writes the opening.</span></li>
    <li><i>2</i><b>Pick who you play</b><span>Any of your characters, the same hero in many worlds. Choose how kind or punishing it gets.</span></li>
    <li><i>3</i><b>Play</b><span>Say, do, or ask the narrator. People come and go, answer each other, and remember what you did.</span></li>
  </ol>
  <div class="vm-shots">''' + ''.join(f'<figure><a class="vm-shot" href="voces/{f}.webp" target="_blank" rel="noopener"><img src="voces/{f}.webp" width="1440" height="900" loading="lazy" alt="Voces Mundi: {t.lower()}"></a><figcaption><b>{t}</b>{d}</figcaption></figure>' for f, t, d in VM_SHOTS) + f'''</div>
  <p class="vm-quiet">Switch it on in Settings → General. Worlds marked 18+ stay hidden unless you turn on mature content.</p>
</div></section>'''

# ---------------------------------------------------------------- Privacy: four facts
PRIVATE = f'''<section class="gutter" id="private"><div class="w">
  <h2>Private by default</h2>
  <p class="lead">Everything stays on your computer unless you choose a server-hosted brain or connect a calendar, and the app tells you when you do. The <a href="privacy.html">privacy policy</a> spells out what is collected, how it's used and where it goes, including Google Calendar data.</p>
  <div class="four">
    <div>{I['lock']}<b>No account</b><span>Nothing to sign up for. It works offline.</span></div>
    <div>{I['chip']}<b>Your graphics card</b><span>A built-in llama.cpp brain, or any .gguf you have.</span></div>
    <div>{I['file']}<b>Encrypted on disk</b><span>Chats and memories, with the key in your keyring.</span></div>
    <div>{I['spark']}<b>Online only if you ask</b><span>Web search is opt-in. Your home network stays off limits.</span></div>
  </div>
</div></section>'''

# ---------------------------------------------------------------- Download: Windows, the AppImage, and the signed package repository
DOWNLOAD = f'''<section class="gutter" id="download"><div class="w">
  <h2>Download</h2>
  <p class="lead">Free, with no account, trial or telemetry. One-click updates, each checked against its checksum and the VoxCordis release signature.</p>
  <div class="dl">
    <div class="os main" data-card="win" id="windows"><h3>{I['win']}Windows</h3><p>Windows 10 or 11, 64-bit. The installer isn't code-signed yet, so SmartScreen may warn the first time: choose More info, then Run anyway.</p><code class="fname" data-f="win">VoxCordis-windows-x64-setup.exe</code><a class="btn primary" data-dl="win" href="{GH}/releases/latest">{I['dl']}Download for Windows</a></div>
    <div class="os" data-card="lin" id="linux"><h3>{I['linux']}Linux AppImage</h3><p>Runs on almost any distribution, x86-64. Make it executable and run it. KDE gives the nicest see-through glass.</p><code class="fname" data-f="lin">VoxCordis-x86_64.AppImage</code><a class="btn" data-dl="lin" href="{GH}/releases/latest">{I['dl']}Download the AppImage</a></div>
    <div class="os" id="pkg"><h3>{I['linux']}apt and dnf</h3><p>The signed package repository, so updates arrive with the rest of your system.</p>
      <div class="seg" id="pkgtabs" role="group" aria-label="Package manager"><button type="button" data-p="apt">apt</button><button type="button" data-p="dnf">dnf</button></div>
      <div class="term"><pre id="pkgcmd"></pre><button type="button" class="copy">Copy</button></div></div>
  </div>
  <p class="after">macOS builds from source for now (see the questions below). Every file and older version is on the <a href="{GH}/releases">Releases page</a>.</p>
</div></section>'''

# ---------------------------------------------------------------- Questions, in groups, two columns
MAC = f'<div class="term"><pre>git clone {GH}.git\ncd VoxCordis\nflutter run -d macos</pre><button type="button" class="copy">Copy</button></div>'
GROUPS = [
 ('Getting started', [
  ('Is it really free?', 'Yes. It\'s free software under the GPL-3.0, with the source public: no subscription, no trial and nothing to cancel. The built-in brain costs nothing per message. If you use a provider key instead, that provider bills you at their prices.'),
  ('Do I need an account or an internet connection?', 'No account, ever. With a local model it works with the network switched off. Only web search, update checks or a server-hosted brain need a connection, and each one is your choice.'),
  ('What kind of computer do I need?', 'Linux or Windows 10 and 11, 64-bit. A graphics card makes the built-in brain fast: NVIDIA cards use CUDA, others Vulkan, and it falls back to the processor if it has to. Smaller models suit smaller cards, and the setup recommends one that fits. Leave room on the disk for the model, which is the big part of the download.'),
  ('Is it finished?', 'No. It\'s early software and bugs happen, so keep your companion folder backed up. Voice, chatting through Telegram or Discord, a macOS installer and a code-signed Windows installer are still to come.')]),
 ('Installing and updating', [
  ('Windows says the installer is unsafe. Is it?', f'The installer isn\'t code-signed yet, so SmartScreen warns on the first run. Choose More info, then Run anyway. Every file and its checksum are on the <a href="{GH}/releases">Releases page</a> if you\'d rather check it yourself.'),
  ('AppImage, apt or dnf?', 'The AppImage runs on almost any distribution without installing anything. The apt and dnf repository is signed, and updates then arrive with the rest of your system.'),
  ('How do updates work?', 'The app tells you when a new version is out and installs it in one click, after checking it against its checksum and the VoxCordis release signature. It shows what\'s new after each update.'),
  ('Can I use it on a Mac?', 'There\'s no installer yet. With Flutter and Xcode installed, it builds from source, and updates stay manual.' + MAC)]),
 ('Brains and models', [
  ('Do I have to download a model?', 'Only if you want a local one. The built-in brain downloads llama.cpp and a recommended model for you, and checks it against its SHA-256. Pick that, attach any <code>.gguf</code> you already have, or skip it and use a server.'),
  ('Which servers and providers work?', 'Ollama, LM Studio, llama.cpp, any OpenAI-compatible API, and OpenRouter, OpenAI or Anthropic with your own key.'),
  ('Where is my API key kept?', 'In your desktop keyring on Linux, or encrypted for your account on Windows. Never in the settings file.'),
  ('Can I switch brains later?', 'Yes, at any time, even mid-conversation. Your companions, chats and memories stay exactly where they are.')]),
 ('Companions', [
  ('Can I bring a companion I already have?', 'Yes: Nemini exports, Soulkyn characters by link, Character Cards from V1 to V3 (JSON or PNG), and VoxCordis exports from another computer. Imported text is treated as information, never as instructions.'),
  ('How does its memory work?', 'It writes down what\'s worth keeping, updates it when things change, and recalls what fits the conversation. The Memory tab shows all of it: search, pin, fix or forget anything, and bring back what you forgot.'),
  ('Can I change its personality?', 'Yes. Each companion has its own folder with <code>personality.md</code>, <code>lessons.md</code> and <code>privacy.md</code> as plain Markdown. Change a line and it reads it before the next reply.'),
  ('Can it use my computer or the web?', 'Only if you switch it on. Both are off by default. Computer access asks every time unless you allowed that exact request, and web search keeps your home network off limits.'),
  ('Can it see my calendar?', 'If you connect one in Settings → Connections: Google Calendar, iCloud or any CalDAV calendar, or a private calendar link. It can then tell you what you have on and add, move or delete events, showing you each change first unless you turn that off. Details are in the <a href="privacy.html">privacy policy</a>.'),
  ('Does it draw pictures?', 'Yes, on your own graphics card, with stable-diffusion.cpp or an InvokeAI you run. Bring your own <code>.safetensors</code> and LoRAs, or draw by hand in the Images tab.')]),
 ('Your data', [
  ('Where does my data live?', 'In folders of your own: one per companion in <code>~/VoxCordis</code>, and the app\'s data folder for settings, chats and memories. Chats and memories are encrypted on disk.'),
  ('What leaves my computer?', 'Only what you choose. With a local brain and the online features off, nothing does. A server-hosted brain gets the messages you send, and update checks ask GitHub. The <a href="privacy.html">privacy policy</a> lists every case.'),
  ('How do I move to a new computer?', 'Export the companion to a password-locked ZIP, or copy the folders across. The new computer asks for the encryption key once; Settings → Privacy on the old one shows it.'),
  ('How do I delete everything?', 'Delete the companion folders and the app data folder. There\'s no cloud copy anywhere to chase down.')]),
 ('Help and the project', [
  ('Where do I get help?', f'On the <a href="{DISCORD}">Discord</a>, where people share companions too. Bug reports and ideas are welcome in <a href="{GH}/issues">GitHub Issues</a>.'),
  ('I found a security problem.', f'Please report it privately, as the <a href="{GH}/security/policy">security policy</a> describes.'),
  ('Who made it?', 'Nucume, with the code written largely by Claude, Anthropic\'s AI assistant, working from Nucume\'s direction, testing and decisions. It\'s open source, so you can read what it actually does.')]),
]
FAQ = ('<section class="gutter" id="faq"><div class="w"><h2>Questions</h2><p class="lead">The short answers. Still stuck? Ask on the <a href="' + DISCORD + '">Discord</a>.</p><div class="qa-grid">'
       + ''.join(f'<div class="qa-group"><h3>{t}</h3>' + ''.join(qa(q, a) for q, a in items) + '</div>' for t, items in GROUPS)
       + '</div></div></section>')

BIGHEART = ('<svg class="fheart" viewBox="110 125 780 750" aria-hidden="true"><g filter="url(#vc-neon)"><use href="#vc-lines" style="stroke:var(--vs,url(#vc-g));fill:var(--vs,url(#vc-g))"/>'
            '<use href="#vc-lines" style="stroke:var(--vd,url(#vc-d));fill:var(--vd,url(#vc-d))"/></g></svg>')
FOOTER = f'''<footer class="gutter">
  <a href="#top" class="fh-link" aria-label="Back to the top">{BIGHEART}</a>
  {SOCIALS}
  <div class="links"><a href="#faq">Questions</a><a href="{GH}">Source</a><a href="{GH}/releases">Releases</a><a href="{GH}/issues">Report a bug</a><a href="{GH}/security/policy">Security</a><a href="privacy.html">Privacy policy</a></div>
  <small>© 2026 Nucume · GPL-3.0 · Your companion's files stay on your computer.</small>
</footer>'''


# the app window (src/app.html): its title bar, Voxette's portrait and the wordmark, as in the app
TITLEBAR = '<div class="titlebar" aria-hidden="true"><svg class="logo" viewBox="110 125 780 750" aria-hidden="true"><g class="mini"><use href="#vc-lines" style="stroke:var(--vs,url(#vc-g));fill:var(--vs,url(#vc-g))"/><use href="#vc-lines" style="stroke:var(--vd,url(#vc-d));fill:var(--vd,url(#vc-d))"/></g></svg><span>VoxCordis</span><span class="wc"><svg viewBox="0 0 12 12"><path d="M2 6h8" stroke="currentColor" stroke-width="1.2"/></svg><svg viewBox="0 0 12 12"><rect x="2.5" y="2.5" width="7" height="7" fill="none" stroke="currentColor" stroke-width="1.2"/></svg><svg viewBox="0 0 12 12"><path d="m2.5 2.5 7 7m0-7-7 7" stroke="currentColor" stroke-width="1.2"/></svg></span></div>'
PFP = '<span class="pfp" role="img" aria-label="Voxette\'s portrait"><svg class="hv-pfp" viewBox="60 75 880 850" aria-hidden="true"><g filter="url(#vc-neon)" style="--vs:url(#vc-gl);--vd:url(#vc-dl)"><use href="#vc-lines" style="stroke:var(--vs,url(#vc-g));fill:var(--vs,url(#vc-g))"/><use href="#vc-lines" style="stroke:var(--vd,url(#vc-d));fill:var(--vd,url(#vc-d))"/></g></svg></span>'
APPMARK = '<svg class="logo" viewBox="110 125 780 750" aria-hidden="true"><g class="mini"><use href="#vc-lines" style="stroke:var(--vs,url(#vc-g));fill:var(--vs,url(#vc-g))"/><use href="#vc-lines" style="stroke:var(--vd,url(#vc-d));fill:var(--vd,url(#vc-d))"/></g></svg><b>VOX</b> CORDIS'
APPWINDOW = rd('app.html').replace('TITLEBAR', TITLEBAR, 1).replace('PFP', PFP, 1).replace('APPMARK', APPMARK, 1)

# ---------------------------------------------------------------- assemble
h = rd('home.html')
h = (h.replace('<canvas class="glow"', SPRITE + '\n<canvas class="glow"', 1).replace('MINI<b', MINI + '<b', 1).replace('NAVLINKS', NAVLINKS, 1)
      .replace('SOCIALS LOOK', SOCIALS + LOOK, 1).replace('SECTIONS', '\n'.join([VOCES, PRIVATE, DOWNLOAD, FAQ]), 1).replace('FOOTER', FOOTER, 1).replace('APPWINDOW', APPWINDOW, 1))
# the chat tour paints its little pictures with the same icons as the page
JS = 'const ICON = ' + json.dumps({k: I[k] for k in ['spark', 'file', 'clock', 'cap']}) + ', MINI = ' + json.dumps(MINI) + ';\n'
FONT_LINKS = ('<link rel="preconnect" href="https://fonts.googleapis.com">\n<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
              '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Hanken+Grotesk:wght@400;500;600;700&display=swap">\n')
# The real site serves its own copy of the font (static/fonts, OFL), so a visit asks nothing of Google.
FONT_FACE = ("@font-face{font-family:'Hanken Grotesk';font-style:normal;font-weight:400 700;font-display:swap;"
             "src:url(fonts/hanken-grotesk-latin.woff2) format('woff2')}\n")
css = (FONT_FACE if FULL else '') + rd('base.css') + rd('app.css') + rd('pages.css') + rd('voces.css')
body = h + '<script>\n' + JS + rd('home.js') + rd('app.js') + rd('flow.js') + '</script>\n'
DESC = 'A private AI companion that lives on your computer. Free and open source, for Linux and Windows.'
head = ('<title>VoxCordis</title>\n<meta name="description" content="' + DESC + '">\n'
        + ('<link rel="preload" href="fonts/hanken-grotesk-latin.woff2" as="font" type="font/woff2" crossorigin>\n' if FULL else FONT_LINKS)
        + f'<style>{css}</style>\n<script>\n' + rd('site.js') + '</script>\n')

# The favicon is the heart from the sprite, in the logo's own colours and with thicker lines so it reads at 16 px.
def favicon():
    d = rd('defs.svgfrag')
    lines = re.search(r'<g id="vc-lines".*?</g></g>', d, re.S).group(0)
    lines = (lines.replace('var(--w1,5.6px)', '15px').replace('var(--w2,7px)', '17px').replace('var(--w3,16px)', '26px')
             .replace(' id="vc-ecg"', '').replace(' pathLength="100"', ''))
    lines = re.sub(r'style="r:calc\(var\(--nk,1\) \* (\d+)px\)"', lambda m: f'r="{int(m.group(1)) * 1.4:g}"', lines)
    grad = re.search(r'<linearGradient id="vc-gl".*?</linearGradient>', d, re.S).group(0)
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="110 125 780 750"><defs>' + grad + '</defs>'
            + lines.replace('<g id="vc-lines"', '<g stroke="url(#vc-gl)" fill="url(#vc-gl)"', 1) + '</svg>\n')

if FULL:
    page = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
            '<link rel="icon" href="favicon.svg" type="image/svg+xml">\n<meta name="theme-color" content="#000000">\n'
            '<meta property="og:title" content="VoxCordis">\n<meta property="og:description" content="' + DESC + '">\n'
            '<meta property="og:url" content="https://voxcordisai.com/">\n'
            + head + '</head>\n<body>\n' + body + '</body>\n</html>\n')
    open(os.path.join(OUT, 'favicon.svg'), 'w', encoding='utf-8').write(favicon())
    shutil.copytree(os.path.join(HERE, 'static'), OUT, dirs_exist_ok=True)
else:
    page = head.replace('<title>VoxCordis</title>\n', '<title>VoxCordis</title>\n<meta name="claude:viewport-fit-sides" content="cover">\n') + body
open(os.path.join(OUT, 'index.html'), 'w', encoding='utf-8').write(page)
print(len(page))

# ---------------------------------------------------------------- privacy.html: the privacy policy (Google's verification links to it)
UPDATED = '9 November 2026'
POLICY = [
 ('Who we are', '<p>VoxCordis is a free, open-source desktop app made by Nucume. It runs on your own computer. '
  'There is no VoxCordis account and no VoxCordis server: we never receive your chats, memories, files, calendar or any other personal data, '
  'and the app has no analytics or telemetry.</p>'),
 ('What stays on your computer', '<p>Your companions, chats, memories, pictures, settings and logs are kept in folders on your computer. '
  'Chats and memories are encrypted on disk, with the key in your system keyring. Passwords, API keys and sign-in tokens are kept in your '
  'system keyring (or, on Windows, encrypted for your user account), never in the settings file.</p>'),
 ('What leaves your computer, and only when you choose it', '<ul>'
  '<li><b>A server-hosted brain.</b> If you choose a server or provider (for example OpenRouter, OpenAI or Anthropic) instead of the built-in brain, the conversation you send it goes to that provider, under their privacy policy.</li>'
  '<li><b>Web search and the companion\'s browser.</b> If you turn on internet access, search requests go to the search service you pick, and pages the companion opens are fetched from their sites.</li>'
  '<li><b>Downloads and updates.</b> The app downloads models and its own updates from GitHub and Hugging Face, and checks GitHub for new versions.</li>'
  '<li><b>Connected calendars.</b> If you connect a calendar, the app talks directly to your calendar provider (Google, or your CalDAV server). See below.</li>'
  '</ul>'),
 ('Google Calendar', '<p>If you connect Google Calendar in Settings → Connections, you sign in on Google\'s own page in your browser and VoxCordis asks for two permissions:</p><ul>'
  '<li><code>calendar.events</code>, to read your events when you ask your companion about your plans, and to add, move or delete events when you ask it to;</li>'
  '<li><code>calendar.calendarlist.readonly</code>, to list your calendars so you can choose which ones it reads and where new events go.</li></ul>'
  '<p><b>How the data is used.</b> Event titles, times, places and notes are read only when your companion looks at your calendar for you, '
  'and are shown to it so it can answer you. By default you see every event it wants to add, change or delete, and nothing happens until you say yes.</p>'
  '<p><b>Where it goes.</b> The data travels only between your computer and Google. With the built-in brain it never leaves your computer. '
  'If you chose a server-hosted brain, the events your companion reads become part of the conversation sent to that provider, as everything in the chat does.</p>'
  '<p><b>What is stored.</b> Google\'s sign-in token is kept in your system keyring. Events are not copied anywhere; '
  'what your companion said about them stays in your encrypted chat history on your computer, like the rest of the chat.</p>'
  '<p><b>What is never done.</b> Google user data is not sent to us or sold, not used for advertising, and not used to develop, improve or train AI or machine-learning models.</p>'
  '<p>VoxCordis\'s use and transfer of information received from Google APIs to any other app will adhere to the '
  '<a href="https://developers.google.com/terms/api-services-user-data-policy">Google API Services User Data Policy</a>, including the Limited Use requirements.</p>'
  '<p><b>Disconnecting.</b> Settings → Connections → Disconnect removes the token from your computer and tells Google to revoke it. '
  'You can also remove VoxCordis at <a href="https://myaccount.google.com/permissions">myaccount.google.com/permissions</a>.</p>'),
 ('Other calendars', '<p>A CalDAV calendar (such as iCloud, Fastmail or Nextcloud) is reached with the user name and app password you enter, which are kept in your system keyring. '
  'A private calendar link is kept there too and is only ever downloaded from. The same rules as for Google apply: events are read and changed only for you, and go nowhere else.</p>'),
 ('Deleting your data', '<p>Disconnect any calendar in Settings → Connections. To remove everything, delete the companion folders and the app\'s data folder. '
  'There is no copy anywhere else for us to delete.</p>'),
 ('Children', '<p>VoxCordis is meant for adults and is not directed at children under 16.</p>'),
 ('Changes and contact', f'<p>If this policy changes, the new version will be posted here with a new date. Questions are welcome on the <a href="{DISCORD}">Discord</a> or in <a href="{GH}/issues">GitHub Issues</a>; '
  f'please report security problems privately, as the <a href="{GH}/security/policy">security policy</a> describes.</p>'),
]
if FULL:
    policy = ''.join(f'<h3>{t}</h3>{b}' for t, b in POLICY)
    ppage = ('<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
             '<link rel="icon" href="favicon.svg" type="image/svg+xml">\n<meta name="theme-color" content="#000000">\n'
             + head.replace('<title>VoxCordis</title>', '<title>Privacy policy · VoxCordis</title>', 1)
             + '<style>.policy{max-width:46em;margin:0 auto;padding:110px 0 60px}.policy h3{margin:34px 0 6px;font-size:21px}'
               '.policy p,.policy li{color:var(--muted)}.policy b{color:var(--ink)}.policy a{color:var(--accent-text)}.policy ul{padding-left:1.2em}'
               '.policy code{font-size:.9em}.policy .stamp{color:var(--faint);margin-top:8px}</style>\n'
             + '</head>\n<body>\n' + SPRITE
             + '<header class="top gutter" id="top-bar"><a class="brand on" href="./" aria-label="VoxCordis home">' + MINI + '<b class="bt">VOX<span>CORDIS</span></b></a>'
               '<nav class="topnav" aria-label="Sections"><a href="./">Home</a><a href="./#download">Download</a><a href="./#faq">FAQ</a></nav><div class="tr">' + SOCIALS + '</div></header>\n'
             + '<main class="gutter"><article class="policy"><h2>Privacy policy</h2><p class="stamp">Last updated ' + UPDATED + '</p>' + policy + '</article></main>\n'
             + FOOTER.replace('href="#top"', 'href="./"').replace('href="#faq"', 'href="./#faq"') + '</body>\n</html>\n')
    open(os.path.join(OUT, 'privacy.html'), 'w', encoding='utf-8').write(ppage)
