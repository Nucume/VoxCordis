# Changelog

VoxCordis shows these notes the first time it starts after an update,
including every version that was skipped on the way. Each `## x.y.z` heading
is one version. While a version is being worked on its notes go under
`## Unreleased`. Tagging a release files them under its version on its own
(the Release workflow), so there is nothing to rename by hand.

A line of its own like `{{action:open-settings}}` becomes a button under
that version's notes (see `lib/features/update/whats_new_dialog.dart` for
the ids); it is left out of the release page.

## Unreleased

### New
- **Your companion can draw.** Turn on *Let your companion draw* in **Settings → Images** and download a picture model: Stable Diffusion XL, Anima Turbo or Anima Aesthetic (anime), Animagine XL 4.0 (anime) or RealVisXL 5.0 (photos). Or add your own .safetensors model, as Civitai offers them. Everything is drawn on your computer with stable-diffusion.cpp, and nothing leaves it. Your companion picks the model and LoRAs for each picture itself, and the picture shows up in the chat a little after its reply. You can draw by hand in the Images tab too, with an Advanced switch for the model, size, steps, guidance, seed and LoRA weights.
- **LoRAs.** Add LoRA files in Settings → Images, with a .txt note beside each for its trigger words, and your companion uses them when they suit.
- **A Booru tags skill** teaches your companion to write Danbooru-style tags for the anime models.
- **A bigger look at pictures.** Click a picture in the gallery or the chat to see it whole, zoom in, or open it in your own picture viewer with *Show file*.
- **Tabs in a new order:** Chat, Images, Memory, Skills, Plans, Settings.
- **Draw through Invoke.** If you run InvokeAI, choose *Draw with: Invoke* in Settings → Images. Your companion sees the models and LoRAs installed in Invoke (Stable Diffusion 1.5, 2 and SDXL) and picks from them, and the pictures come back into the chat like any other. The Images tab no longer warns when Invoke isn't running.
- **Export a companion.** Open the companion menu (tap the name) and choose **Export**: one ZIP with the personality, lessons, privacy rules, memories, plans, chat and folder files, laid out like a Nemini export. It is locked with a password by default, since the ZIP leaves the encrypted database behind; settings and API keys never go in. Bring it back with **Import a character** (Nemini or VoxCordis) when adding a companion, here or on another computer. Reminders and automations come back paused.

### Fixed
- **What's new shows again after updating.** 0.2.4 went out with its notes still filed as unreleased, so it showed nothing. If you are on 0.2.4, you will see its notes together with this version's.
- **The day you're on stays highlighted in the right place.** Scrolling the Days list no longer leaves the highlight stuck over the top of the list.
- **Open-source parts in About** opens on a solid page instead of turning the whole window see-through.
- **A bigger smallest window.** The window can't get smaller than 1140×720 any more. On short windows the portrait shrinks so the days and the folder button stay in view, and on narrow ones the tabs show only their icons instead of being cut off.
- **Haru works in the light theme**, with dark ink instead of a pale grey that vanished on white.

### Changed
- **Glassy pickers.** Colorway, ready light, pokes, tasks, search service, memory span, chat format and Repeat open the same frosted menu as the companion switcher, a little more compact, with the chosen option ticked.
- **The background picture sits in the big panel on the right** only, behind the chat and the other tabs. The companion card and the window around it keep the colorway.
- **Close to the system tray.** "Keep running when I close the window" is now **Close to the system tray**: closing the window leaves a VoxCordis icon in the tray. Click it to come back, or right-click for Open and Quit. On Linux it shows on KDE, Cinnamon, XFCE and GNOME with the AppIndicator extension; where there is no tray, the window goes to the taskbar as before.
- **Appearance has its own Settings tab**, right after General: colorway, background picture, theme and the ready light. The separate Accent picker is gone, since the colorway sets the accent.

## 0.2.4

### New
- **Skills.** Skills teach your companion how to do particular things, in the new **Skills** tab. It comes with proofreading, weather, price watch and a morning briefing, plus an ADHD support mode you can switch on. While a skill is on, your companion uses it whenever it fits. Type `/` in the chat to call one up yourself, like `/weather Bern` or `/proofreading` followed by your text. A task in the Plans tab can call one too, such as a daily `/morning-briefing`.
- **Your own skills.** Write a new skill in the Skills tab, or import one: a SKILL.md, a Markdown file, or a Claude skill (.zip or .skill) works as it is. Your companion can also write a skill when you ask it to learn something for good. Those wait for you to read them and turn them on.
- **Looks.** Settings → General has ready-made looks (Twilight, Rose, Ocean, Forest, Ember, Moonlight) that change the accent and the colour glows together. Your companion can pick one too.
- **Colorways.** One Colorway list, each with a glossy colour orb. The six standard looks change the accent and glows; the three special ones below the line recolour the whole window and panels too: Haru (monochrome, with red kept to accents like the send button and the selected tab), Vibecoder's (indigo) and Sakura (soft pink on deep plum).
- **Poke.** After three hours with nobody writing, your companion does something on its own: sends you a message, potters about with its notes, or falls into a web rabbit hole when Internet is on. It pokes once and then waits for you, or keeps poking while you're away if you switch that on, and never in your quiet hours (11 pm to 8 am unless you change them). Set it up under Settings → General, below In the background.
- **A background picture.** Choose any picture to sit behind the whole app, darkened so everything stays readable, with a Darkness slider. Each companion keeps its own, and can set one from its folder itself.

### Fixed
- **Pressing Enter right after typing keeps your last letter.** Typing fast could push the last letter into the start of the next message.
- **Typing in the chat box no longer stutters.** Holding Backspace or typing quickly made the box lag behind, because the frosted blur behind the panels was drawn again for every key. The main panels now skip that blur. The background behind them holds still, so they look the same.
- **The chat opens at your newest message**, every time you come back to it.
- **A half-written message stays** when you visit another tab and come back, pictures and files included.
- **The window can't be squeezed too small** any more.
- **Dropdown menus are solid** instead of see-through.
- **Settings tidy-up.** Quit VoxCordis sits at the very bottom of General, and the encryption key field in Privacy is a single line.

### Changed
- **Join the community.** About has a button to the VoxCordis Discord, for help, news and sharing companions.
- **About** shows what VoxCordis is, its version and updates, its GPL-3.0 licence, a link to the source code and the open-source parts it is built from.
- **The ready light** is a big Discord-style dot on the portrait's bottom-right corner now, and the VoxCordis logo moved to the companion card, leaving the top bar free. Right-click the light to move it next to the name or back to the chat's top bar, or pick its place in Settings → General.

## 0.2.3

### New
- **Your companion can go online.** Turn on *Settings → Internet* and your companion can search the web and read pages for news, weather, facts and anything current. What it reads is treated as information only, never as instructions, and after reading the web it can't use your computer until you write again. Your own computer and home network are always off limits, and you can list sites it must never visit. DuckDuckGo works without an account; Brave Search, Tavily or your own SearXNG can be used instead.
- **A browser of its own, without a window.** For sites that need clicking or typing, your companion can use an invisible browser: Edge, Chrome, Chromium, Brave or Vivaldi from your computer, or a small one VoxCordis downloads once. It has its own profile without your logins or history, never types into password fields, and asks you before it sends a form.
- **Reminders and tasks.** Ask "remind me at 6 to call Mum" or "every weekday morning, check the weather for me". Reminders arrive in the chat in your companion's own words, with a desktop notification. Tasks are jobs your companion does on its own at a time, then tells you about. See, change, pause or add them in the new **Plans** tab. Tasks never get to use your computer, and a daily limit keeps a server-hosted brain's bill in check.
- **Keep running in the background.** *Settings → General → Keep running when I close the window* keeps reminders and tasks going with the window closed, and *Start with my computer* starts VoxCordis when you log in.
- **Nemini reminders and automations** come along when you import a Nemini export. They arrive paused, so you can check them in the Plans tab first.
- **Your chats and memories are encrypted.** They're now stored encrypted on your computer, and the data you already had was encrypted on this first start. The key is kept in your keyring (or encrypted for your Windows account), so nothing changes day to day. **Copy your key** from *Settings → Privacy* and keep it somewhere safe: a new computer, or a reset keyring, will ask for it. You can also make a new key there, or use your own password.
- **Your companion can see.** Share pictures with the paperclip, by dragging them onto the chat, or with Ctrl+V. Models that can see look at them themselves: server-hosted ones like Claude or GPT, and the new Qwen3-VL models in the list. For any other model, download **Eyes** in *Settings → Brain → Sight*: a small vision model that looks at each picture on your computer and describes it for your companion.
- **Share text files.** Notes, code, JSON and other text files can be attached the same way, and your companion reads them.
- **Free the graphics card for games.** Turn on *Settings → Brain → Free the graphics card when I'm not chatting*, and after a minute without typing the model leaves graphics memory. Typing loads it again.
- **What's new after updating.** The first start after an update shows what changed, including every version you skipped. *Settings → About* shows it again.

{{action:open-privacy}}
{{action:open-sight}}
{{action:open-internet}}

## 0.2.0

### New
- **More than one companion.** Switch between companions from the companion card, add another one, or browse them all in a gallery.
- **Import a character** during setup. You can bring one in from a Nemini export (memories, chat and notes), a Soulkyn link or Character Card files (JSON or PNG). The app can also rewrite the imported personality in the companion's own words.
- **System access**, off by default. With your OK, the companion can run commands and open apps, folders, files and web addresses. Every request asks first. "Always allow" applies to one exact request, and programs and scripts are asked about every time.
- **Cloud brains.** OpenRouter, OpenAI and Anthropic are quick picks under Server-hosted, alongside Ollama, LM Studio and any OpenAI-compatible server.
- **Light theme.** Choose System, Light or Dark. The companion can switch it, and restyle its background and accent colour.
- **Chat tools.** You can stop or retry a reply, and delete a message along with everything after it.
- **Brain settings.** Chat format and temperature are now in Brain → Advanced.

### Fixed
- Replies no longer hang or freeze the window.
- Mistral Nemo no longer forgets the conversation.
- ChatML models stop cleanly at the end of a reply.
- The companion now opens folders reliably when asked in everyday words.
- The companion speaks to you by name, rather than about you.

### Security and privacy
- **Your API key** is kept in your desktop keyring on Linux, and encrypted for your account on Windows. It is no longer stored in plain text in the settings file. An existing key is moved over automatically.
- **Chats, memories, settings and companion folders** can only be read by your user account.
- **Soulkyn sign-in:** the browser window used for importing forgets the login when it closes.
- **Updates and downloads:** model downloads are pinned to an exact version and checked against a checksum. Updates and the built-in runtime are only installed when their checksum matches.
- **The local model server** needs a fresh random key every time it starts.

### Known
- The Windows installer isn't code-signed yet, so SmartScreen may warn the first time you run it.
