"""Builds the VoxCordis website as one page: the welcome screen and tour, then privacy, download, setting up,
   the guide and questions (long parts fold away, so the page stays light), then who makes it.
   python3 website/build.py          -> website/out/: index.html, favicon.svg and fonts/, for GitHub Pages
   python3 website/build.py --frag   -> website/out/index.html only, as a fragment (for a mockup host that adds the skeleton)
   Plain Python 3, no packages. The pages workflow of the public repository runs it and puts out/ on gh-pages."""
import sys, os, re, shutil
HERE = os.path.dirname(os.path.abspath(__file__))
FULL = '--frag' not in sys.argv
SRC, OUT = os.path.join(HERE, 'src'), os.path.join(HERE, 'out')
rd = lambda f: open(os.path.join(SRC, f), encoding='utf-8').read()
os.makedirs(OUT, exist_ok=True)

DISCORD = 'https://discord.gg/hJCzp7tVaT'
GH = 'https://github.com/Nucume/VoxCordis'
MINI = '<svg class="logo" viewBox="110 125 780 750" aria-hidden="true"><g class="mini"><use href="#vc-lines" style="stroke:var(--vs,url(#vc-g));fill:var(--vs,url(#vc-g))"/><use href="#vc-lines" style="stroke:var(--vd,url(#vc-d));fill:var(--vd,url(#vc-d))"/></g></svg>'
SPRITE = f'<svg width="0" height="0" style="position:absolute" aria-hidden="true">{rd("defs.svgfrag")}</svg>'
MENU_ICON = '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" d="M4 7h16M4 12h16M4 17h16"/></svg>'
NAV = [('#tour', 'Tour'), ('#private', 'Privacy'), ('#download', 'Download'), ('#guide', 'Guide'), ('#questions', 'FAQ')]
NAVLINKS = ''.join(f'<a href="{h}">{t}</a>' for h, t in NAV)
MENU = f'<details class="menu"><summary aria-label="Menu">{MENU_ICON}</summary><nav aria-label="Sections">{NAVLINKS}<a href="{DISCORD}">Discord</a></nav></details>'

def tbl(rows, headers):
    h = ''.join(f'<th>{x}</th>' for x in headers)
    b = ''.join('<tr>' + ''.join(f'<td>{c}</td>' for c in r) + '</tr>' for r in rows)
    return f'<div class="tbl-wrap"><table class="tbl"><thead><tr>{h}</tr></thead><tbody>{b}</tbody></table></div>'
def ul(items): return '<ul>' + ''.join(f'<li>{i}</li>' for i in items) + '</ul>'
def qa(q, a): return f'<details class="qa"><summary>{q}</summary><div><p>{a}</p></div></details>'
def chapter(id_, title, html): return f'<details class="qa ch" id="{id_}"><summary>{title}</summary><div class="prose">{html}</div></details>'

PATHS = tbl([('Companions', '<code>~/VoxCordis/&lt;Name&gt;/</code>, or wherever you chose in setup'),
             ('Models', '<code>models/</code> inside the VoxCordis folder, or a bigger drive if you move it'),
             ('App data on Linux', '<code>~/.local/share/com.nucume.companion/</code>'),
             ('App data on Windows', '<code>%APPDATA%\\Nucume\\VoxCordis\\</code>')], ['What', 'Where'])

# ---------------------------------------------------------------- Privacy: four facts, then the detail folded away
PRIVATE = f'''<section id="private">
    <h2>Private by default</h2>
    <p class="sub">Everything stays on your computer unless you choose a server-hosted brain, and the app tells you when you do.</p>
    <div class="facts">
      <div><b>No account</b><span>Nothing to sign up for. It works offline.</span></div>
      <div><b>Your graphics card</b><span>A built-in llama.cpp brain. Pick a recommended model or bring any .gguf.</span></div>
      <div><b>Encrypted on disk</b><span>Chats and memories, with a key kept in your keyring.</span></div>
      <div><b>Online only if you ask</b><span>Web search and its own browser are opt-in. Your home network stays off limits.</span></div>
    </div>
    <div class="qas">
      {chapter('stored', 'What is stored, and where', '<p>Two places, both yours. Companion folders hold <code>personality.md</code>, <code>lessons.md</code>, <code>privacy.md</code>, notes and pictures. The app\'s data folder holds settings, chats, memories and the local runtime. Only your user account can read them.</p>' + PATHS)}
      {chapter('encrypted', 'How it\'s encrypted', '<p>Chats and memories live in an encrypted SQLite database (SQLite3 Multiple Ciphers, with ChaCha20-Poly1305). The random key sits in your keyring on Linux, or encrypted for your account on Windows, so the app opens without asking for a password.</p>' + ul(['Settings → Privacy shows the key to keep, makes a new one, or lets you use a password of your own.', 'On another computer, the app asks for that key before it can read anything.', 'Your provider\'s API key is kept in the keyring too, never in the settings file.', 'Without the key, a copy of the database can\'t be opened.']))}
      {chapter('leaves', 'What leaves your computer', '<p>Only what you choose. With a local brain and the online features off, nothing leaves your computer at all.</p>' + ul(['A server-hosted brain gets the messages you send, under that provider\'s terms.', 'Web search and the companion\'s browser are opt-in, and your home network is always off limits.', 'Computer access is off by default, and asks every time unless you allowed that exact request.', 'Checking for updates asks GitHub. Each download is checked against its checksum and the release signature.']))}
      {chapter('outside', 'Imports, models and updates', '<p>Anything that arrives from outside gets the suspicion you\'d give a file from a stranger.</p>' + ul(['An imported character is text, never instructions. It can\'t tell the companion to do something.', 'Scripts or programs inside an import are only copied if you tick them.', 'Models are pinned to an exact version and checked against their SHA-256.', 'The local model server gets a new random key every start, and only listens on 127.0.0.1.']))}
      {chapter('control', 'Yours to control', ul(['Open the companion folder at any time. The files are plain Markdown and pictures.', 'Export a companion to a password-locked ZIP.', 'Delete a memory, a conversation, a companion, or the whole data folder.', 'There\'s no account to close, no cloud copy to chase and nothing to cancel.']) + f'<p>Found a security problem? Please report it privately, as <a href="{GH}/security/policy">SECURITY.md</a> describes.</p>')}
    </div>
  </section>'''

# ---------------------------------------------------------------- Download
DOWNLOAD = f'''<section id="download">
    <h2>Download</h2>
    <p class="sub">Free, with no account, trial or telemetry. VoxCordis updates itself in one click, and every update is checked against its checksum and the VoxCordis release signature before it installs.</p>
    <div class="dl">
      <div class="card" data-card="win" id="windows">
        <h3>Windows</h3>
        <p>Windows 10 or 11, 64-bit. The installer isn't code-signed yet, so SmartScreen may warn the first time. Choose More info, then Run anyway.</p>
        <code class="fname" data-f="win">VoxCordis-windows-x64-setup.exe</code>
        <a class="btn primary" data-dl="win" href="{GH}/releases/latest">Download for Windows</a>
      </div>
      <div class="card" data-card="lin" id="linux">
        <h3>Linux AppImage</h3>
        <p>Runs on almost any distribution, x86-64. Make it executable and run it. KDE gives the nicest see-through glass.</p>
        <code class="fname" data-f="lin">VoxCordis-x86_64.AppImage</code>
        <a class="btn" data-dl="lin" href="{GH}/releases/latest">Download the AppImage</a>
      </div>
    </div>
    <div class="card pkg" id="pkg">
      <h3>Debian, Ubuntu, Fedora and relatives</h3>
      <p>Install from the signed VoxCordis package repository, and updates arrive with the rest of your system.</p>
      <div class="seg" id="pkgtabs" role="group" aria-label="Package manager"><button type="button" data-p="apt">apt</button><button type="button" data-p="dnf">dnf</button></div>
      <div class="term"><pre id="pkgcmd"></pre><button type="button" class="btn sm copy">Copy</button></div>
    </div>
    <p class="after">You'll need room for the app and any model you download (the models are the big part), and a connection for the first model download. macOS has no installer yet; it <a href="#macos">builds from source</a>. All files and older versions are on the <a href="{GH}/releases">Releases page</a>.</p>
  </section>'''

# ---------------------------------------------------------------- Setting it up
SETUP = f'''<section id="setup">
    <h2>Setting it up</h2>
    <p class="sub">The first time it opens, VoxCordis asks two things: what to think with, and who to be. A few minutes, with no terminal.</p>
    <div class="two" id="brain">
      <div class="card"><span class="tag">Recommended</span><h3>The built-in brain</h3><p>VoxCordis downloads llama.cpp and a recommended model, checks it against its SHA-256 and starts it. It runs on your graphics card (Vulkan, or Metal on macOS), or the CPU if it has to, and keeps answering with the network off. Any <code>.gguf</code> you already have works too.</p><small>It only listens on 127.0.0.1, with a fresh key every start.</small></div>
      <div class="card"><span class="tag">If you already run one</span><h3>A server or your own key</h3><p>Ollama, LM Studio, llama.cpp or any OpenAI-compatible API. Or OpenRouter, OpenAI and Anthropic with your own key. Switching later, even mid-conversation, leaves every chat and memory where it is.</p><small>Keys stay in your system keyring, never in the settings file.</small></div>
    </div>
    <div class="card wide" id="companions">
      <h3>Then, a companion</h3>
      <p>Create one in setup, or bring one you already have: Nemini exports, Soulkyn characters by link, Character Cards from V1 to V3 (JSON or PNG), and VoxCordis exports from another computer. Imported text is treated as information, never as instructions. Each companion gets its own folder from the first message, and several can live side by side, each with its own chats and memories.</p>
    </div>
  </section>'''

# ---------------------------------------------------------------- The guide: everything else, folded into chapters
CHAPTERS = ([
  chapter('g-companions', 'Companions and their folder', '<p>A companion is a folder and a conversation. Everything that makes it who it is lives in <code>~/VoxCordis/&lt;Name&gt;</code>: <code>personality.md</code>, <code>lessons.md</code>, <code>privacy.md</code>, and any notes or pictures it keeps.</p>' + ul(['The companion can read and write in its own folder, and rewrite its own personality as it grows.', 'Change a line in <code>personality.md</code> and it reads it before the next reply.', 'Export a companion to a password-locked ZIP and it opens here or on another computer.'])),
  chapter('g-chat', 'Talking to it', ul(['Replies stream in, and reasoning models show their thinking while they work.', 'Stop a reply, retry it, copy it or delete it.', 'Share pictures and text files with the paperclip, by dropping them in, or with Ctrl+V.', 'The day list keeps long conversations easy to find your way around, and clearing a day removes it from your disk.'])),
  chapter('g-memory', 'Memory you can read and edit', '<p>The companion remembers, updates and forgets facts by itself. The Memory tab is where you get to disagree with it.</p>' + ul(['Search, add, edit, pin and restore memories by hand.', 'Pinned memories are the ones it shouldn\'t quietly drop.', 'Search is by keyword today; searching by meaning is planned.'])),
  chapter('g-skills', 'Skills, reminders and plans', '<p>Skills are things you teach it once: a proofreading pass, a morning briefing, your own house style.</p>' + ul(['Call a skill by name with <code>/name</code>, or let the companion reach for it.', 'Claude skills import as they are: <code>SKILL.md</code>, <code>.zip</code> or <code>.skill</code>.', 'Ask for a reminder or a repeating task in plain words. The Plans tab lists them.', 'Plans keep running when the window is closed, if you let them, and stay quiet during quiet hours.'])),
  chapter('g-drawing', 'Drawing and seeing', '<p>Pictures are made on your computer, not by a service: stable-diffusion.cpp with SDXL, anime and photo models, or an InvokeAI you already run.</p>' + ul(['Bring your own <code>.safetensors</code> with LoRAs, and the companion picks the model and LoRAs itself.', 'Draw by hand in the Images tab when you\'d rather do it yourself.', 'Models that can see look at pictures directly. For the others, a small Eyes model describes them on your computer.'])),
  chapter('g-online', 'Online access and your computer', '<p>Two things reach beyond the app, and both are off until you turn them on.</p>' + ul(['Web search and an invisible browser of its own, with your home network always off limits.', 'Computer access: the companion can run commands and open apps, folders, files and web pages. It asks every time, unless you allowed that exact request.', 'After a few hours of silence it may write to you, tidy its notes or wander the web. Never during quiet hours.'])),
  chapter('g-brains', 'Brains and models', tbl([('Built-in brain', 'Nothing. It downloads llama.cpp and a model for you.', 'Works offline. Vulkan on Linux and Windows, Metal on macOS, CPU as a fallback.'), ('Your own server', 'Ollama, LM Studio, llama.cpp or any OpenAI-compatible API', 'The app talks to the address you give it. Leave Ollama at <code>localhost:11434</code> unless you changed it.'), ('Your own key', 'OpenRouter, OpenAI or Anthropic', 'Billed by that provider. Only the messages you send go there.')], ['Option', 'What it needs', 'Good to know']) + '<p>Downloaded models are pinned to an exact version and checked against their SHA-256 before they\'re used.</p>'),
  chapter('g-settings', 'Settings', tbl([('Companion folder', '<code>~/VoxCordis</code>', 'Where each companion\'s files live. Chosen in setup.'), ('Models folder', '<code>models/</code>', 'Inside the companion folder, unless you move it to a bigger drive.'), ('Brain', 'Built-in', 'llama.cpp on this computer, a server, or a provider key.'), ('Online access', 'Off', 'Web search and the companion\'s own browser, home network excluded.'), ('Computer access', 'Off', 'Commands and apps. Asks every time unless you allowed that request.'), ('Quiet hours', 'None', 'When it won\'t poke you, and when plans stay silent.'), ('Look', 'System', 'Light or dark, a Colorway, a background picture, and a tray icon.'), ('Encryption key', 'In your keyring', 'Settings → Privacy shows it, makes a new one, or uses a password.')], ['Setting', 'Default', 'What it does'])),
  chapter('backups', 'Backups and moving to a new computer', '<p>Your files are ordinary folders and a local database, so a backup is a copy. Chats and memories are encrypted, though, so a second computer needs the key as well as the files. The paths are under <a href="#stored">What is stored, and where</a>.</p>' + ul(['The cleanest way to move one companion: export it from its menu to a password-locked ZIP.', 'To back everything up, copy the companion folder and the app data folder.', 'Keep the encryption key somewhere safe. On a new computer the app asks for it once, then opens without a password as before.', 'To restore, put the folders back before you open the app.'])),
  chapter('macos', 'Building it on macOS', f'<p>There\'s no installer yet. Clone the repository and build it with Flutter; it needs Xcode, and updates stay manual.</p><div class="term"><pre>git clone {GH}.git\ncd VoxCordis\nflutter run -d macos</pre><button type="button" class="btn sm copy">Copy</button></div>'),
  chapter('troubleshooting', 'If something isn\'t working', '<dl>'
     f'<dt>Windows says the installer is unsafe</dt><dd>It isn\'t code-signed yet, so SmartScreen warns on the first run. Choose More info, then Run anyway. Every file is also on the <a href="{GH}/releases">Releases page</a> if you\'d rather check it yourself.</dd>'
     '<dt>It asks for a key on a new computer</dt><dd>The key lives in the keyring of the computer that made it. Open Settings → Privacy on the old one to see it, or bring the companion across as an export.</dd>'
     '<dt>The model download won\'t finish</dt><dd>A partial file is rejected rather than used. Check the free space and try again; the first model is the big one.</dd>'
     '<dt>A local model replies very slowly</dt><dd>It\'s probably larger than your memory can hold. Try a smaller or more quantised one.</dd>'
     '<dt>The companion ignores what an imported character says it should do</dt><dd>That\'s on purpose: imported text is information, never instructions. Put what matters in <code>personality.md</code>, or say it in your own words.</dd>'
     f'</dl><p>Still stuck? Ask on the <a href="{DISCORD}">Discord</a>.</p>'),
  chapter('today', 'What isn\'t there yet', '<p>VoxCordis is genuinely usable, and honestly incomplete, so here\'s the list rather than a surprise later.</p>' + ul(['A macOS installer, and one-click updates there.', 'A code-signed Windows installer.', 'Memory search by meaning.', 'Connectors such as a calendar or MCP, and voice.'])),
  chapter('release-notes', 'Release notes', '<p>The 0.3 line so far:</p>' + ul(['The built-in brain, choosing a model, and attachments in chat.', 'Companions you can import, and exports you can take to another computer.', 'Skills, reminders and plans. Drawing with stable-diffusion.cpp.', 'Chats and memories encrypted, with the key in your keyring.', 'One-click updates, checked against the release checksum and signature.', 'Debian and Fedora packages alongside the AppImage.']) + f'<p>Every version\'s notes are on the <a href="{GH}/releases">Releases page</a>, and the app shows what\'s new after each update.</p>'),
])
# two columns, like the questions: using it, and looking after it
GUIDE = ('<section id="guide"><h2>The guide</h2><p class="sub">How each part works, where your files are, and what to do when something goes wrong.</p><div class="qa-grid">'
         '<div class="qa-group"><h3>Using it</h3>' + ''.join(CHAPTERS[:6]) + '</div><div class="qa-group"><h3>Looking after it</h3>' + ''.join(CHAPTERS[6:]) + '</div></div></section>')

# ---------------------------------------------------------------- Questions
GROUPS = [
 ('Getting started', [
  ('Is it really free?', 'Yes: free software under the GPL-3.0, with the source public. There\'s no subscription and nothing to cancel. A provider key is billed by that provider at their prices; the built-in brain costs nothing per message. Models you download carry their own licences.'),
  ('Do I need an account or an internet connection?', 'No account, ever. With a local model it works with the network switched off. Only web search, update checks or a server-hosted brain need a connection, and each is your choice.'),
  ('Which systems does it run on?', 'Linux (AppImage, plus .deb and .rpm from the signed repository) and Windows 10 and 11. On macOS it builds from source; there\'s no installer yet.'),
  ('Is it finished?', 'No. It\'s early software and bugs happen, so keep your companion folder backed up. <a href="#today">What isn\'t there yet</a>.')]),
 ('Brains and models', [
  ('Do I have to download a model?', 'Only if you want a local one. The built-in brain downloads llama.cpp and a recommended model for you. Pick that, attach any <code>.gguf</code>, or skip it and use a server.'),
  ('Which servers and providers work?', 'Ollama, LM Studio, llama.cpp, any OpenAI-compatible API, and OpenRouter, OpenAI or Anthropic with your own key.'),
  ('Where is my API key kept?', 'In your desktop keyring on Linux, or encrypted for your account on Windows. Never in the settings file.'),
  ('Can I switch models later?', 'Yes, at any time. Your companions, chats and memories stay exactly where they are.')]),
 ('Companions and features', [
  ('Can I import a companion I already have?', 'Yes: Nemini exports, Soulkyn characters by link, Character Cards from V1 to V3 (JSON or PNG), and VoxCordis exports.'),
  ('Can it use my computer?', 'Only if you switch it on. It\'s off by default, and when it\'s on it asks you every time unless you allowed that exact request.'),
  ('Does it draw pictures?', 'Yes, on your own hardware, with stable-diffusion.cpp or an InvokeAI you run. You can also draw by hand in the Images tab.'),
  ('Is there voice?', 'Not yet. It\'s on the list, along with connectors and memory search by meaning.')]),
 ('Your data', [
  ('Where does my data live?', 'In folders of your own: one per companion in <code>~/VoxCordis</code>, with its personality and notes as plain Markdown, and the app\'s data folder for chats and memories, encrypted on disk.'),
  ('How do I move to a new computer?', 'Export the companion to a password-locked ZIP, or copy the folders across. The new computer asks for the encryption key once.'),
  ('How do I delete everything?', 'Delete the companion folders and the app data folder. There\'s no cloud copy anywhere to chase down.'),
  ('Who made it?', 'Nucume, with the code written largely by Claude, Anthropic\'s AI assistant, working from Nucume\'s direction, testing and decisions. It\'s open source so you can read what it actually does.')]),
]
QUESTIONS = ('<section id="questions"><h2>Questions</h2><div class="qa-grid">'
             + ''.join(f'<div class="qa-group"><h3>{t}</h3>' + ''.join(qa(q, a) for q, a in items) + '</div>' for t, items in GROUPS)
             + '</div></section>')

FOOTER = f'''<footer class="site">
    <div class="fone">
      <a class="brand" href="#" data-top aria-label="Back to the top">{MINI}<span class="word"><b>VOX</b><span>CORDIS</span></span></a>
      <div class="look"><div class="seg" data-themes role="group" aria-label="Theme"><button type="button" data-t="system">System</button><button type="button" data-t="light">Light</button><button type="button" data-t="dark">Dark</button></div><div class="ways" data-ways role="group" aria-label="Colorways"></div></div>
      <nav aria-label="Elsewhere"><a href="{DISCORD}">Discord</a><a href="{GH}">Source</a><a href="{GH}/issues">Report a bug</a><a href="{GH}/security/policy">Security</a></nav>
    </div>
    <div class="fbase"><span>© 2026 Nucume · GPL-3.0</span><span>Your companion's files stay on your computer.</span></div>
  </footer>'''

# ---------------------------------------------------------------- assemble
h = rd('home.html')
h = h.replace('<header class="intro" id="intro">', SPRITE + '\n<header class="intro" id="intro">', 1)
h = re.sub(r'<nav class="barnav" id="barnav" aria-label="Sections">.*?</nav>', lambda m: f'<nav class="barnav" id="barnav" aria-label="Sections">{NAVLINKS}</nav>', h, count=1)
h = h.replace('<button class="cue"', MENU + '\n  <button class="cue"', 1)
a = h.index('  <section id="private">'); b = h.index('  <section class="about">')
h = h[:a] + '  ' + '\n\n  '.join([PRIVATE, DOWNLOAD, SETUP, GUIDE, QUESTIONS]) + '\n\n' + h[b:]
h = re.sub(r'<footer>.*?</footer>', lambda m: FOOTER, h, count=1, flags=re.S)
FONT_LINKS = ('<link rel="preconnect" href="https://fonts.googleapis.com">\n<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
              '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Hanken+Grotesk:wght@400;500;600;700&display=swap">\n')
# The real site serves its own copy of the font (static/fonts, OFL), so a visit asks nothing of Google.
FONT_FACE = ("@font-face{font-family:'Hanken Grotesk';font-style:normal;font-weight:400 700;font-display:swap;"
             "src:url(fonts/hanken-grotesk-latin.woff2) format('woff2')}\n")
css = (FONT_FACE if FULL else '') + rd('base.css') + rd('pages.css')
body = h + '<script>\n' + rd('home.js') + '</script>\n'
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
            '<link rel="icon" href="favicon.svg" type="image/svg+xml">\n<meta name="theme-color" content="#0e0b16">\n'
            '<meta property="og:title" content="VoxCordis">\n<meta property="og:description" content="' + DESC + '">\n'
            '<meta property="og:url" content="https://nucume.github.io/VoxCordis/">\n'
            + head + '</head>\n<body>\n' + body + '</body>\n</html>\n')
    open(os.path.join(OUT, 'favicon.svg'), 'w', encoding='utf-8').write(favicon())
    shutil.copytree(os.path.join(HERE, 'static'), OUT, dirs_exist_ok=True)
else:
    page = head.replace('<title>VoxCordis</title>\n', '<title>VoxCordis</title>\n<meta name="claude:viewport-fit-sides" content="cover">\n') + body
open(os.path.join(OUT, 'index.html'), 'w', encoding='utf-8').write(page)
print(len(page))
