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
- **Video generation (extreme early access).** Open any picture in Images and press **Animate** to turn it into a short clip, made on your computer. This is very new and barely tested: expect crashes, running out of memory, odd or broken-looking clips, and slow runs of many minutes. It has only been tried on one graphics card so far, so the length ruler (green, amber, red) is a rough guess. Models are in Settings → Images → Video models: Wan 2.2 (5B and the bigger 14B; silent clips), LTX 2.5 and MiniMax H3 (both make sound too, and both are huge downloads of 30 to 43 GB that want a lot of computer memory). "Write it for me" turns a few words into a prompt that suits the model. Clips show in the gallery with a play symbol. If something goes wrong, Settings → Logs has what the engine printed; please report it.
- **Room for small windows.** The window can now be as narrow as 820 pixels (it was 1140). Below 1140, the companion card folds away into a menu button left of Chat, and that button brings the card back over the page. Make the window wider again and the card unfolds into its place.
- **LoRAs fold away.** In Images → Draw → Advanced, the LoRAs sit under a header you can open and close. Closed, only the ones you picked stay, with their strength sliders, and the header says how many are on. It remembers whether you left it open.
- **Arrows on the Settings tabs.** When the window is too narrow for every Settings tab, an arrow appears on the side with more tabs; click it to move along.

### Fixed
- **Resizing the window keeps what you were doing.** Making the window narrow enough to fold the companion card (or wide again) rebuilt the tabs, so a reply you were editing, the chat's scroll position and a prompt typed in Draw were lost.
- **The Animate window fits narrow windows.** Its buttons no longer run off the edge.
- **Switching companions waits for a reply that started meanwhile.** A reminder reply that began while the "Save your changes?" question was open could end up in the other companion's chat.
- **A model that finishes downloading is chosen even if you moved to another Settings page.** Before, it was only chosen if you stayed on Brain.
- **A CUDA llama-server that hangs while loading uses Vulkan on the next try.** It no longer tries CUDA again for the rest of that run.
- **Chats set aside can always be brought back on Linux.** If "I lost the key" was used while the keyring was still locked, the next start (or setting your own password later) wrote over the old key that was still in the keyring, so the set-aside chats could never be opened again. Every key the app replaces is now kept for Settings → Privacy → Chats set aside.
- **The unlock screen no longer gets in the way of typing the key.** Its check every 5 seconds took the cursor out of the key field and ignored Enter while it ran. If starting over can't move the chats aside, it now says so instead of freezing.
- **A failed update leaves your chats working.** If the update could not be put in place (an antivirus holding the installer, say), the chats stayed closed until a restart. The chats are now closed only once the new version is on its way.
- **Updating while the old version is still open no longer moves its data away.** If VoxCordis 0.3.7 or older was still running (in the tray, say) when the new version started, the new one moved the data folder out from under it, and what the old window saved from then on was lost. The new version now brings the old window forward instead and says to quit it first.
- **Your data comes along even when part of it won't move.** If something in the old data folder couldn't be moved (on another drive, or held open), the app could start as if it were new and never try again. It now copies what is on another drive, always brings your settings, and tries the rest again at the next start.
- **The system title bar shows on the first start after updating.** On Linux, with "Use the system title bar" on, the first start of the renamed app had no title bar at all.
- **Old update installers are cleaned up.** On Windows each update left its `VoxCordis-x.y.z-setup.exe` in the temporary folder for good. The app now deletes them at the next start, and a failed download is removed straight away.
- **A reply you are editing stays open when a reminder comes in.** If a reminder, task or nudge made the companion reply while you were rewriting one of its messages, your rewrite was thrown away. It now stays open and you can save it once the reply is written.
- **Lessons keep your last letter.** Pressing Enter right after typing a lesson (or Ctrl+Enter in a reply you edited) could drop the last letter on Linux.
- **Saving Settings no longer puts the tabs back across the top.** Picking "Down the side" in Appearance and pressing Save switched it back; it now stays.
- **Save in Settings only saves what you changed there.** Anything changed elsewhere while Settings was open (a video's volume, a model you moved, a look or theme the companion picked) is no longer put back the way it was when the page opened.
- **Switching companions asks about unsaved Settings first.** Switching or adding a companion while Settings had unsaved changes threw them away without asking; now you get Save, Discard or Cancel.
- **Reset and Delete wait for the reply to finish.** Resetting or deleting a companion mid-reply could send the rest of that reply's memories, reminders and restyling to the next companion, or back into the one just wiped.
- **A companion can't take another's folder in Settings.** Two companions sharing a folder could make one of them vanish from the list.
- **After deleting your only companion, the next one starts fresh.** It no longer inherits the old one's colour and pronouns.
- **A CUDA runtime that won't start is replaced by Vulkan.** If the NVIDIA (CUDA) llama-server can't start, for example because a library is missing, VoxCordis tries the Vulkan one by itself and says why in Settings → Logs, instead of showing a runtime error. It only switches when Vulkan really does start the model: a model file that won't load anywhere, or no internet to fetch Vulkan, no longer turns CUDA off for a day. Pictures (Eyes) and memory search (Recall) switch the same way, and once CUDA has failed it stays off until the app restarts.


## 0.3.8

### Changed
- **The browser the app downloads is checked.** The headless Chrome it fetches for web pages is now one pinned version whose SHA-256 is checked before it is unpacked, like the other downloaded programs.
- **The Windows installer says who made it.** Its file properties now name Nucume and VoxCordis, which helps antivirus programs trust it.

### Fixed
- **Chats no longer lock themselves after the app was closed mid-write.** When VoxCordis was stopped while saving (the computer shut down, it ran out of memory, a crash), the next start could show "Unlock your chats" even though the key was right there. It now opens as normal.
- **Updating and quitting finish saving first.** The update and Quit now write the last bits and close the chat database before the app stops, instead of cutting a save off half-way (which is what tripped the lock above).
- **The unlock screen waits for your keyring.** If VoxCordis starts at login before GNOME Keyring or KWallet is unlocked, the screen now opens by itself as soon as the key can be read, and has a Try again button.
- **"I lost the key" keeps the old key.** Starting over no longer writes over the only copy of the old key. Chats set aside can be brought back in Settings → Privacy, added to the chats you have now.

### Changed
- **The program is now called voxcordisai.** On Windows it is `voxcordisai.exe` (it was `companion.exe`) and on Linux the binary is `voxcordisai`, so there is no doubt what it is in Task Manager or a virus scan. The app's id is now `com.nucume.voxcordis` too (your data folder on Linux is `~/.local/share/com.nucume.voxcordis/`). The first start moves everything over from the old folder, and updating removes the old program file.

## 0.3.7

### Fixed
- **No more video player error at startup.** When the video player can't load on Linux (libmpv missing or a different version), video portraits show their still picture and gallery clips open in your own video player, instead of an error in Logs. Logs says once why videos play outside the app.
- **Video portraits play again on newer Linux desktops.** The video player now uses whichever libmpv your system has (libmpv.so.2 or the older libmpv.so.1), instead of only the one the release was built with.

## 0.3.6

- **Link buttons in About.** Settings → About has a row of glass icon buttons for the VoxCordis website, GitHub, Discord, Reddit and X, each in its brand colour. The icons come from Simple Icons (CC0).
### New
- **A better download bar.** Every download (models, the browser, updates) now has a thicker bar in your Colorway with a light sweep over it, the percentage under it and the time left beside that. The time appears after a few seconds, once the speed is known.
- **Edit your companion's replies, and they learn from it.** Hover a reply and press the pencil to rewrite it in place (Ctrl+Enter saves, Esc cancels). The edited reply replaces the old one, so later turns see your version. Your companion then compares the two and suggests a short lesson, like "Keep replies short and casual", which you can reword, keep or skip; kept lessons go into lessons.md and are read before every reply. Fixing a typo or a comma doesn't ask.
- **Much faster model downloads.** Language and drawing models (and the runtimes) now download over several connections at once instead of one, starting with four and adding more for as long as the speed keeps rising, so a fast line (2.5 or 10 Gbit) gets filled while a slow one isn't flooded. A cut download still picks up where it stopped. The progress bar also redraws less often, so the app stays smooth meanwhile.
- **Faster on NVIDIA cards.** An NVIDIA card with a recent driver now gets llama.cpp's CUDA build instead of Vulkan, which reads long chats and writes replies noticeably faster; other cards keep Vulkan. On Linux the CUDA build comes with the VoxCordis release (checked against the release key before it is used) and falls back to Vulkan if it isn't there. The model's memory of the chat (KV cache) is also stored in 8-bit with flash attention, which roughly halves its size with almost no change in quality, and only one chat slot is reserved. The new runtime downloads once the next time the model starts.
- **Native Windows notifications with your companion's picture.** Reminders and task results now appear as proper Windows toasts: your companion's portrait beside their name and the message, and clicking one brings VoxCordis back.
- **Windows is asked directly.** Notifications, finding your GPU memory, the usual folders, starting with your computer and the app list now ask Windows directly instead of starting PowerShell or other programs. Commands your companion runs (still asked first) use PowerShell 7 (`pwsh`) when it is installed, and the PowerShell that comes with Windows otherwise. That is the one place a shell is still needed. And "open an app" finds apps with a Start menu shortcut.
- **Interface size.** Settings → Appearance has a new slider that makes everything, text included, 80–150% of what your computer's scaling says. It only goes as big as the window has room for.
- **Start On-Screen.** Under Settings → General, "Start with my computer" is now a choice: Disabled, Start On-Screen (the window opens when you log in) or Start Minimized (it goes to the tray or taskbar, as before).
- **Allow everything.** With "Let your companion use this computer" on, Settings → Computer has a new switch that lets commands and opens run without asking each time. It is off by default, turning it on shows a warning that it can be highly destructive and that you use it at your own risk, and turning off computer access turns it off too.
- **Download a Kyn's whole Soulkyn gallery.** Pictures has a new "Download all Images & Videos" button: paste a Kyn's link and every picture and video in its Soulkyn gallery is saved into Pictures, with an option to leave NSFW ones out. Pressing it again later only fetches what is new. Videos show in Pictures with a play sign and play right in the app. Importing a Kyn from Soulkyn offers the same button on the "Who is your companion?" step.
- **Soulkyn remembers your login.** The Soulkyn window now stays logged in between imports, avatar and gallery downloads, and restarts, so private characters work without signing in each time. "Log out of Soulkyn" in the download dialog forgets it.
- **Delete and Show in folder in the viewer.** A picture or video opened in Pictures now has a folder button that opens its folder with the file picked out, and a Delete button that asks first and moves it to your computer's trash, so it can still be brought back.

### Fixed
- **Small or heavily scaled screens.** On a screen with little room left after scaling (say 1080p at 200%), the window now opens and stays within the screen, and the interface shrinks to fit instead of being cut off.
- **Windows notifications say VoxCordis.** They were filed under "Windows PowerShell".
- **VoxCordis opens only once.** Starting it again brings the running window forward, also from the tray or the taskbar, instead of opening a second copy.
- **Soulkyn characters with a video avatar.** Importing one now brings over a still from the video as the portrait, instead of a broken or missing picture.
- **No more "Connection closed while receiving data".** When the built-in model stops in the middle of a reply (it crashed, ran out of memory, or was restarted because a setting changed), VoxCordis now starts it again and writes the reply once more by itself. If it happens twice in a row you get a plain explanation instead of the technical error, and Settings → Logs → Chat keeps the model's last words before it stopped, which helps find the cause. Saving settings or drawing a picture no longer restarts the model while a reply is being written.

### Changed
- **A tidier LoRA picker.** In Draw's advanced options, LoRAs are now glass buttons across the panel's width instead of a long list. Pick one and its strength slider appears right under its name. The LoRAs you pick are remembered for each model, like the other advanced options.

## 0.3.5

### New
- **Companions manage their own skills.** Your companion can now switch skills on and off to keep the ones they need at hand, and write a new skill when you teach them how to do something. Skills they write still wait for your OK in the Skills tab. Up to 8 skills can be on at once, so they don't fill every prompt; the Skills tab shows how many are on.
- **Test this key.** Under Settings → Brain → Server-hosted, a new button next to the API key checks that the service accepts it, without sending a message or spending anything.
- **Buttons for questions.** Your companion can now end a question with a few buttons to press. A press sends that option as your reply, exactly as if you had typed it, and you can always answer in your own words instead. The buttons stop working once any reply has been sent.
- **Tables, links and more in chat.** Markdown tables show as tables, `[links](https://...)` and web addresses are tappable (VoxCordis asks before opening one), and `_italic_` and `__bold__` work like the star versions.

### Fixed
- **Companions use their skills more.** When what you say fits one of your companion's skills (asking whether you need an umbrella, say), VoxCordis now puts that skill's instructions right in front of them, found by meaning with Recall, instead of hoping they think of reading it. The list of skills they see is clearer, with the best fit first, and also names the ones that are off.
- **The draw panel remembers.** Pictures → Draw something yourself keeps the Advanced switch, the shape and the model you picked across restarts, and each model keeps its own width, height, steps, guidance, seed and negative prompt, so switching models brings back what that model was last given. A Reset button puts a model's numbers back to its defaults.
- **Resizable prompt fields.** Drag the grip in the bottom right corner of the prompt and negative prompt boxes to see more of a long prompt (double-click it to go back to fitting the text). Ctrl+Enter (or Cmd+Enter) draws, and a button between Width and Height swaps them.
- **Code blocks in chat.** Text between ``` fences now shows as a boxed, monospace block with a copy button on hover, instead of loose text with stray backticks. Blank lines inside a block are kept as written. Quotes (`> like this`) and divider lines (`---`) show properly too.

## 0.3.4

### New
- **A shorter prompt that keeps the thread.** Each reply used to carry the last 40 messages, which is why your companion sometimes said the same things again. Now it gets the last six exchanges as they are, plus "the story so far": a short summary of what came before, which your companion rewrites in the background as messages age out of that window (right after a reply, so your next message isn't kept waiting). Together with Recall's moments from older chat it keeps the thread without rereading everything. Rewinding the chat drops a story that told of the deleted messages.
- **Recall by meaning.** Settings → Brain offers Recall, a small embedding model (EmbeddingGemma 300M, a 0.3 GB download) that lets your companion find memories by what they mean rather than by matching words: ask about "that place with the great ramen" and the memory about the restaurant comes up. It also brings up moments from older chats that fit what you're saying, dated, so your companion keeps the thread without rereading everything. It runs on this computer, on the processor, with any brain, server-hosted ones too. Without it, memories are matched by words as before.
{{action:open-settings}}
- **Reset a companion.** The Danger zone also has "Reset <name>": they forget every chat, memory and reminder but keep their name, personality and folder. One confirmation, by typing a sentence with their name.
- **Logs.** Settings → Logs shows what your companion's browser, web searches, thoughts, tool calls, replies and drawing (prompt, tags, LoRAs, seed) did, so you can see why something went wrong. Turn logs off entirely or pick which kinds to keep. They stay on your computer in the companion's database (encrypted like the chat), API keys are blanked out, and the oldest lines go after 7 days, 5,000 lines or 8 MB. Copy them, save them as a file, or clear them.
- **Delete a companion.** Settings → General has a new Danger zone that deletes the companion you're talking to, chats and memories included. You confirm twice, the second time by typing a sentence with their name exactly as shown, capitals included, and can choose to remove their folder too. You then continue with another companion, or go back to setup if it was the last one.
- **apt and dnf packages.** On Debian, Ubuntu, Fedora and relatives VoxCordis can now be installed as a `.deb` or `.rpm` from a signed repository (the commands are at https://voxcordisai.com/#download). Your system's updater then keeps it current. A copy installed that way doesn't update itself; the update window shows the command to run instead.

### Fixed
- **"Exceeds the available context size" errors.** A long chat, or switching to a built-in model with a shorter memory span, could make every message fail because the chat no longer fitted. VoxCordis now leaves out the oldest messages so it always fits the memory span (your companion's rules, personality and memories stay in). If a model still says it's too long, VoxCordis learns its real limit, trims a little more and asks again instead of showing an error.
- **Companion's browser stopping.** If VoxCordis was closed hard or crashed while the browser was open, that browser kept running in the background and every later start of the browser failed at once. VoxCordis now closes the leftover browser (or uses a fresh profile) and always closes its browser when quitting. Pop-up dialogs on a page no longer freeze it, and a crashed page reopens instead of hanging.

## 0.3.3

### New
- **Latest button.** Scrolled up in the chat, a Latest button floats in at the bottom and takes you back down to the newest message.


### Fixed
- **OpenRouter models without tool support.** Some models have no provider that takes tools, and OpenRouter answered with a 404. VoxCordis now chats with them without tools and says so in the chat. Their memory still works in a simpler way: the companion writes a short note and VoxCordis saves it, though small models may miss it now and then.
- **Dragging the chat's scrollbar.** Dragging the bar at the side made the chat jump around, because the chat only guessed its full length until every message had been seen. It now knows the real length, so the bar moves smoothly.
- **Chat opening partway up.** Coming back from a past day could leave the chat at the top of the day instead of at the newest message. It now opens at the newest one. Setting or removing a background picture no longer resets the chat either; switching tabs keeps your place.
- **Closing a picture.** A click beside a picture you're looking at now closes it, not only the X.

### Changed
- **Verified releases.** Release commits are signed, so GitHub shows them as Verified.

## 0.3.2

### New
- **Settings asks before losing changes.** Leave Settings after changing something without saving, and VoxCordis asks whether to save or discard them, or stay.


### Fixed
- **Switching tabs is quicker.** Chat, Images, Memory, Skills and Plans stay ready once opened instead of being built again each time, so going back is instant and keeps your place. The Images gallery only loads the pictures in view.
- **Settings opens on General again.** After using the settings button in the Images tab, it kept opening on Images.
- **No more big empty replies after long thoughts.** Some models write a pile of blank lines after thinking, which left the reply bubble mostly empty with the text at the bottom. Those blank lines are now dropped, also in replies you already have.

## 0.3.1

### New
- **A VoxCordis title bar** on Windows and Linux, in the app's own colours, with minimise, maximise and close. Drag it to move the window, double-click it to maximise. Prefer your system's bar? Turn on *Use the system title bar* in **Settings → Appearance**. On KDE that brings back the Breeze bar instead of the big GTK one. On Windows 11, hovering the maximise button still offers Snap Layouts.

### Changed
- **A much bigger Booru tags skill.** Your companion now has the real Danbooru vocabulary for faces, eyes, hair, clothes, poses, lighting, composition and adult scenes, split into small files it reads only when a picture needs them, so it fits even a small memory span. If you never changed the old Booru tags skill, it is replaced on its own; if you did, *Restore starter skills* in the Skills tab brings in the new one.

### Fixed
- **Open and Save dialogs look like your system's.** On Linux they come from your desktop now, so KDE shows its own file dialog. On Windows they no longer draw in the old classic style.
- **Pickers in Settings no longer bump into each other.** The ones at the end of a row line up and have room to breathe.
- **The Colorway orb fades with the theme.** Switching between dark and light no longer makes it jump to the new colours before the rest of the window.
- **VoxCordis has its icon on Linux** in the system tray, Alt+Tab and the taskbar, instead of an empty spot or a generic "W". It also shows up in your app menu now.

## 0.3.0

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
