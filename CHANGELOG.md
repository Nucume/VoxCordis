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

### Changed
- **Google Calendar only goes to AI that doesn't train on it.** Google doesn't allow calendar data to reach AI services that may train on it. Google Calendar now works with the built-in brain, a server on your own computer or home network, OpenAI, Anthropic and OpenRouter. With OpenRouter, VoxCordis asks only for providers that don't keep or train on what they're sent. Other server-hosted brains don't get your Google Calendar; CalDAV and calendar links are unchanged.

## 0.4.3

### New
- **Your companion can use your calendar.** Settings → Connections connects:
  - Google Calendar (you sign in in your browser).
  - Any CalDAV calendar, such as iCloud, Fastmail or Nextcloud.
  - A private calendar link from any provider.
  - Your companion can tell you what you have on. With Google or CalDAV it can also add, move and delete events.
  - By default you see every change and say yes or no first.
  - Sign-ins and passwords stay in your keyring. Nothing goes through a VoxCordis server.
- **Use VoxCordis from your phone.** Turn on Settings → Connections → Phone access.
  - Pair: scan the code with your phone's camera and say yes on your PC.
  - No camera: choose **Pair a phone** on the PC, tap **Pair with my PC** on the phone, check both screens show the same five-letter code and allow it. This also works for an iPhone home-screen app, which doesn't share Safari's sign-in.
  - The phone's browser shows your chat (photos too), pictures, simple drawing and Voces Mundi stories, all running on your PC.
  - Nothing to install; you can add it to your home screen.
  - Home network only. Every phone must be paired and allowed on the PC, and the traffic is encrypted.
  - With Tailscale on both, it also works away from home.
  - Switching companions on the phone switches the PC too.
  - If your companion wants the web or your calendar while answering from the phone, it asks on the phone.
  - Draw on the phone has the PC's Advanced settings: model, size and ratio, steps, guidance, seed, sampler, scheduler and LoRAs with strength. What you pick there is what the PC's Draw panel shows next.
  - Firewall keeping phones out? The Phone access page says so, and **Let phones through** opens the port for your home network only, after your computer asks for your password once (Linux with ufw or firewalld, Windows, macOS). Turning phone access off offers to close it again.
  - The phone page uses the whole screen. Its tabs slide away while you scroll back or type, and return as you scroll toward the newest message.
  - Phones coming and going show under the new **Connections** kind in the logs.

### Changed
- **Bring your Soulkyn chats along.** Export a chat on Soulkyn (a .csv file) and import it.
  - For a companion: "Import a Soulkyn chat…" in Settings → General, or add it while setting up a companion from Soulkyn. Messages go into the chat in written order, and your companion can read them for things worth remembering.
  - For an RPG chat where the Kyn plays many people: Import → A Soulkyn chat makes a Voces Mundi story that picks up where you left off, with its people and story notes read from the chat.
- **Export moved to Settings.** Export and the Soulkyn chat import now sit together in Settings → General, under your companion's name. The companion menu is shorter.

### Fixed
- **Long chats open and answer faster.** A chat with tens of thousands of messages (after a long import, say) used to slow down with every message. It now takes the same few milliseconds at any length.
- **Photos in chat use far less memory.** A phone photo is now kept at the size it is shown, not at full size (about 50 MB each before).
- **Smoother settings.** With a special colorway or your own glow colours, saving a setting no longer fades the window to identical colours, and dragging a slider no longer saves once per step.
- **The PC stays smooth while a phone looks at pictures.** Pictures sent to a paired phone are encrypted in the background.
- **Recall keeps up with long chats.** It used to read everything from disk for every reply. It now keeps it in memory (about 3 KB per exchange) and reads it once.
- **Voces Mundi stories survive a model crash.** If the model stops mid-turn, it is restarted and the turn is written again, as chat replies already did. Before, the turn ended with "The model stopped".
- **The desktop stays smooth while a model is loaded.**
  - A card filled to llama.cpp's 1 GB margin made every window crawl while being resized.
  - The chat model now leaves 2 GB of graphics memory free, and the memory span suggestion keeps 2 GB for the desktop (was 0.5 GB). Artemis 31B on a 24 GB card now suggests 16k.
  - Recall's embedding model no longer opens the graphics card at all.
  - A larger span may now spill some layers to the processor, which is slower; a smaller span keeps full speed.
- **No white window when a picker has one option.** A single-option glass picker could turn the window white.

## 0.4.2

### New
- **Voces Mundi, the RPG system, first version.**
  - Fully toggleable: if you don't want it, you never see it.
  - Persistent characters, multiple NPCs in worlds, lorebooks, tagging mechanics and more.
  - 0.4.2-a1 fixed most bugs, but some are still to be expected.
- **Bigger, newer models to download.**
  - 24 GB cards (RTX 3090, 4090): Qwen3.8 27B (smartest all-rounder, recommended), Artemis 31B (best writing) and Orion 26B (roleplay, about as fast as an 8B model); Artemis and Orion are built on Gemma 4.
  - 10-16 GB cards: Gemma 4 12B (modern all-rounder that can see pictures, now recommended) and Rocinante X 12B (successor to Rocinante 12B).
- **Older models folded away.** Rocinante 12B and Mistral Nemo 12B moved to a folded "Older models" list at the bottom of the model picker. They keep working if you already have them.

### Fixed
- **CUDA drawing on Linux, for real this time.**
  - 0.4.1 brought CUDA drawing, but its Linux engine wasn't part of that release, so Linux kept using Vulkan.
  - With an NVIDIA card, drawing and animating now switch to CUDA within a day, or straight away if you delete `master-920-2f88688.no-cuda` in the app's `draw` folder and restart.
  - Settings → Logs says "Drawing with the CUDA build of sd-cli." when it is in use.
- **No more GitHub 403 blocking the CUDA download.**
  - GitHub allows only 60 lookups an hour per address to apps that aren't signed in, and refused the lookup past that (HTTP 403). Drawing stayed on slower Vulkan for a day.
  - The app now finds the download through GitHub's public releases feed, which has no such limit. It is still installed only if the release key signed it.
  - If GitHub refuses anyway, it retries an hour later (not a day), and Settings → Logs says which request was refused and why.
- **Asking for a picture gets one.**
  - Roleplay models sometimes described a photo in the story instead of drawing it.
  - Your companion is now told plainly that only drawing makes a picture.
  - If a reply still skips it, the app asks once more behind the scenes and the picture follows the reply.

## 0.4.1

### New
- **Sampler and Scheduler in Draw → Advanced.**
  - Pick any sampler (Euler a, DPM++ 2M, ER-SDE and more) and scheduler (Karras, Beta, Simple and more), or leave them on the model's own.
  - Kept per model with its other numbers; Reset puts them back.
- **Your own ratio.** A fourth button next to Square, Portrait and Landscape opens a field for any ratio: "9:16", "16 9", "4/3" or "4x3".
  - Without a typed size, the picture keeps about the model's usual pixel count in that ratio.
  - In Advanced, typing the height sets the width from the ratio (and the other way round). The swap button turns 9:16 into 16:9.
- **The size stays when you switch models.** Width, Height and the ratio in Draw → Advanced no longer change with the model.
- **Shape buttons in Advanced too.** Square, Portrait and Landscape set the size in one click (832 x 1216, 1216 x 832 or 1024 x 1024 on SDXL-sized models), putting a typed size aside. Hover a button to see its size.
- **Drawing uses CUDA on NVIDIA cards.**
  - Windows and Linux, with a recent enough driver: drawing and animating run on CUDA instead of Vulkan, usually faster.
  - The CUDA engine is a one-time extra download.
  - If it can't be downloaded or won't start, drawing falls back to Vulkan and tries CUDA again a day later. Settings → Logs says why.

### Fixed
- **Your own Anima finetunes draw.**
  - A finetune like SunstoneGemAnima in the picture models folder failed with "new_sd_ctx_t failed": it was run as a whole checkpoint without Anima's VAE and text encoder.
  - It now borrows those from Anima Turbo or Anima Aesthetic (download one of them too).
  - Files that are only part of a model (Flux, Qwen Image, Z-Image) show in Settings → Images with a note that they can't run, instead of failing when picked.
- **Drawing says why it couldn't start.**
  - Instead of only "new_sd_ctx_t failed", it names the cause in plain words (graphics card out of memory, missing or damaged file, your own file isn't a model it can run, graphics driver didn't start) and what to try.
  - A missing model part is caught before drawing starts.

## 0.4.0

### New
- **Video generation (extreme early access).**
  - Open any picture in Images and press **Animate** to make a short clip on your computer.
  - Very new and barely tested: expect crashes, running out of memory, odd clips, and slow runs of many minutes.
  - Tried on one graphics card only, so the length ruler (green, amber, red) is a rough guess.
  - Models are in Settings → Images → Video models:
    - Wan 2.2 (5B and bigger 14B): silent clips.
    - LTX 2.5 and MiniMax H3: clips with sound, but huge downloads (30 to 43 GB) that want a lot of computer memory.
  - "Write it for me" turns a few words into a prompt that suits the model.
  - Clips show in the gallery with a play symbol.
  - If something goes wrong, Settings → Logs has what the engine printed. Please report it.
- **Room for small windows.** The window can be as narrow as 820 px (was 1140).
  - Below 1140, the companion card folds into a menu button left of Chat, which brings the card back over the page.
  - Make the window wider and the card unfolds into place.
- **LoRAs fold away.** In Images → Draw → Advanced, LoRAs sit under a header you can open and close.
  - Closed, only the ones you picked show, with their strength sliders, and the header says how many are on.
  - It remembers whether you left it open.
- **Arrows on the Settings tabs.** When the window is too narrow for every tab, an arrow appears on the side with more tabs.

### Fixed
- **Resizing keeps what you were doing.** Folding or unfolding the companion card rebuilt the tabs and lost an edited reply, the chat's scroll position and a typed Draw prompt.
- **The Animate window fits narrow windows.** Its buttons no longer run off the edge.
- **Switching companions waits for a reply already started.** A reminder reply that began while "Save your changes?" was open could land in the other companion's chat.
- **A finished model download is chosen wherever you are in Settings.** Before, only if you stayed on Brain.
- **A hanging CUDA llama-server falls back to Vulkan.** After hanging while loading, it no longer tries CUDA again for the rest of that run.
- **Chats set aside can always be brought back on Linux.**
  - If "I lost the key" was used while the keyring was locked, the next start (or setting your own password) overwrote the old key still in the keyring, so those chats could never be opened.
  - Every key the app replaces is now kept for Settings → Privacy → Chats set aside.
- **The unlock screen no longer gets in the way of typing the key.** Its check every 5 seconds took the cursor out of the field and ignored Enter. If starting over can't move the chats aside, it says so instead of freezing.
- **A failed update leaves your chats working.** If the update couldn't be put in place (an antivirus holding the installer, say), chats stayed closed until a restart. They now close only once the new version is on its way.
- **Updating while the old version is open no longer moves its data away.**
  - If VoxCordis 0.3.7 or older was still running (in the tray, say), the new version moved the data folder out from under it, and what the old window saved was lost.
  - The new version now brings the old window forward and says to quit it first.
- **Your data comes along even when part of it won't move.** If something in the old data folder couldn't move (another drive, held open), the app could start as if new and never retry. It now copies what is on another drive, always brings your settings, and retries the rest at the next start.
- **The system title bar shows on the first start after updating.** On Linux with "Use the system title bar" on, the first start of the renamed app had no title bar.
- **Old update installers are cleaned up.** On Windows each update left its `VoxCordis-x.y.z-setup.exe` in the temporary folder. They are now deleted at the next start, and a failed download is removed straight away.
- **A reply you are editing stays open when a reminder comes in.** A reminder, task or nudge reply used to throw away your rewrite. Now you can save it once the reply is written.
- **Lessons keep your last letter.** Pressing Enter right after typing a lesson (or Ctrl+Enter in an edited reply) could drop the last letter on Linux.

## 0.3.8

### Changed
- **The program is now called voxcordisai.**
  - Windows: `voxcordisai.exe` (was `companion.exe`). Linux: binary `voxcordisai`. No doubt what it is in Task Manager or a virus scan.
  - The app id is now `com.nucume.voxcordis` (Linux data folder: `~/.local/share/com.nucume.voxcordis/`).
  - The first start moves everything over from the old folder, and updating removes the old program file.
- **The downloaded browser is checked.** The headless Chrome fetched for web pages is one pinned version, with its SHA-256 checked before unpacking, like the other downloaded programs.
- **The Windows installer says who made it.** Its file properties name Nucume and VoxCordis, which helps antivirus programs trust it.

### Fixed
- **Chats no longer lock themselves after the app was closed mid-write.** After a shutdown, out-of-memory or crash while saving, the next start could show "Unlock your chats" with the right key in place. It now opens normally.
- **Updating and quitting finish saving first.** Update and Quit write the last bits and close the chat database before stopping, instead of cutting a save off (which caused the lock above).
- **The unlock screen waits for your keyring.** If VoxCordis starts at login before GNOME Keyring or KWallet is unlocked, the screen opens by itself once the key can be read, and has a Try again button.
- **"I lost the key" keeps the old key.** Starting over no longer overwrites the only copy. Chats set aside can be brought back in Settings → Privacy, added to your current chats.

## 0.3.7

### Fixed
- **No more video player error at startup.** If the video player can't load on Linux (libmpv missing or a different version), video portraits show their still picture and gallery clips open in your own video player. Logs says once why.
- **Video portraits play again on newer Linux desktops.** The player uses whichever libmpv your system has (libmpv.so.2 or the older libmpv.so.1), not only the one the release was built with.

## 0.3.6

### New
- **Link buttons in About.** Glass icon buttons for the VoxCordis website, GitHub, Discord, Reddit and X, each in its brand colour (icons from Simple Icons, CC0).
- **A better download bar.** Models, the browser and updates get a thicker bar in your Colorway with a light sweep, the percentage under it and the time left beside it (shown after a few seconds, once the speed is known).
- **Edit your companion's replies, and they learn from it.**
  - Hover a reply and press the pencil to rewrite it in place (Ctrl+Enter saves, Esc cancels). Later turns see your version.
  - Your companion compares the two and suggests a short lesson, like "Keep replies short and casual". Reword, keep or skip it.
  - Kept lessons go into lessons.md and are read before every reply.
  - Fixing a typo or a comma doesn't ask.
- **Much faster model downloads.**
  - Language and drawing models (and runtimes) download over several connections, starting with four and adding more while speed keeps rising. Fast lines (2.5 or 10 Gbit) get filled; slow ones aren't flooded.
  - A cut download still resumes.
  - The progress bar redraws less often, so the app stays smooth.
- **Faster on NVIDIA cards.**
  - A recent NVIDIA driver now gets llama.cpp's CUDA build instead of Vulkan: faster long chats and replies. Other cards keep Vulkan.
  - On Linux the CUDA build ships with the VoxCordis release (checked against the release key) and falls back to Vulkan if missing.
  - The chat's memory (KV cache) is stored in 8-bit with flash attention: roughly half the size, almost no quality change, and only one chat slot is reserved.
  - The new runtime downloads once, the next time the model starts.
- **Native Windows notifications with your companion's picture.** Reminders and task results appear as Windows toasts with their portrait, name and message. Clicking one brings VoxCordis back.
- **Windows is asked directly.** Notifications, GPU memory, the usual folders, start with your computer and the app list now ask Windows directly instead of starting PowerShell.
  - Commands your companion runs (still asked first) use PowerShell 7 (`pwsh`) if installed, else the PowerShell that comes with Windows. That is the one place a shell is still needed.
  - "Open an app" finds apps with a Start menu shortcut.
- **Interface size.** A Settings → Appearance slider scales everything, text included, to 80–150% of your computer's scaling. It only goes as big as the window has room for.
- **Start On-Screen.** Under Settings → General, "Start with my computer" is now a choice: Disabled, Start On-Screen (window opens at login) or Start Minimized (tray or taskbar, as before).
- **Allow everything.**
  - With "Let your companion use this computer" on, a new Settings → Computer switch lets commands and opens run without asking.
  - Off by default. Turning it on warns that it can be highly destructive and is at your own risk.
  - Turning off computer access turns it off too.
- **Download a Kyn's whole Soulkyn gallery.**
  - Pictures has a new "Download all Images & Videos" button: paste a Kyn's link and every picture and video in its gallery is saved to Pictures, with an option to skip NSFW ones.
  - Pressing it again only fetches what is new.
  - Videos show a play sign and play in the app.
  - Importing a Kyn from Soulkyn offers the same button on the "Who is your companion?" step.
- **Soulkyn remembers your login.** The Soulkyn window stays logged in between imports, avatar and gallery downloads, and restarts, so private characters work without signing in. "Log out of Soulkyn" in the download dialog forgets it.
- **Delete and Show in folder in the viewer.** A picture or video opened in Pictures has a folder button (opens its folder with the file picked out) and a Delete button that asks first and moves it to your computer's trash.

### Changed
- **A tidier LoRA picker.** In Draw's advanced options, LoRAs are glass buttons across the panel instead of a long list. Pick one and its strength slider appears under its name. Picks are remembered per model.

### Fixed
- **Small or heavily scaled screens.** With little room left after scaling (say 1080p at 200%), the window opens and stays within the screen, and the interface shrinks to fit.
- **Windows notifications say VoxCordis.** They were filed under "Windows PowerShell".
- **VoxCordis opens only once.** Starting it again brings the running window forward, also from the tray or taskbar.
- **Soulkyn characters with a video avatar.** Import brings a still from the video as the portrait, not a broken or missing picture.
- **No more "Connection closed while receiving data".**
  - When the built-in model stops mid-reply (crash, out of memory, restart after a setting change), VoxCordis restarts it and writes the reply again by itself.
  - Twice in a row gives a plain explanation instead of the technical error. Settings → Logs → Chat keeps the model's last words before it stopped.
  - Saving settings or drawing a picture no longer restarts the model while a reply is being written.

## 0.3.5

### New
- **Companions manage their own skills.**
  - They can switch skills on and off to keep the ones they need, and write a new skill when you teach them something. Skills they write still wait for your OK in the Skills tab.
  - Up to 8 skills can be on at once, so they don't fill every prompt. The Skills tab shows how many are on.
- **Test this key.** Under Settings → Brain → Server-hosted, a button next to the API key checks that the service accepts it, without sending a message or spending anything.
- **Buttons for questions.** Your companion can end a question with a few buttons. A press sends that option as your reply, as if typed; you can always answer in your own words. The buttons stop working once any reply has been sent.
- **Tables, links and more in chat.**
  - Markdown tables show as tables.
  - `[links](https://...)` and web addresses are tappable (VoxCordis asks before opening one).
  - `_italic_` and `__bold__` work like the star versions.

### Fixed
- **Companions use their skills more.** When what you say fits a skill (asking whether you need an umbrella), its instructions are put in front of your companion, found by meaning with Recall. The skill list is clearer, best fit first, and also names the ones that are off.
- **The draw panel remembers.**
  - Pictures → Draw something yourself keeps the Advanced switch, shape and model across restarts.
  - Each model keeps its own width, height, steps, guidance, seed and negative prompt. A Reset button restores the defaults.
- **Resizable prompt fields.**
  - Drag the grip at the bottom right of the prompt and negative prompt boxes (double-click to fit the text again).
  - Ctrl+Enter (or Cmd+Enter) draws.
  - A button between Width and Height swaps them.
- **Code blocks in chat.** Text between ``` fences shows as a boxed monospace block with a copy button on hover, not loose text with stray backticks. Blank lines inside are kept. Quotes (`> like this`) and divider lines (`---`) show properly too.

## 0.3.4

### New
- **A shorter prompt that keeps the thread.**
  - Replies used to carry the last 40 messages, which is why your companion sometimes repeated itself.
  - Now they get the last six exchanges as they are, plus "the story so far": a short summary of what came before, rewritten in the background as messages age out (right after a reply, so your next message isn't kept waiting).
  - With Recall's moments from older chat, it keeps the thread without rereading everything.
  - Rewinding the chat drops a story that told of the deleted messages.
- **Recall by meaning.**
  - Settings → Brain offers Recall, a small embedding model (EmbeddingGemma 300M, 0.3 GB download) that finds memories by meaning, not matching words: ask about "that place with the great ramen" and the restaurant memory comes up.
  - It also brings up dated moments from older chats that fit what you're saying.
  - Runs on this computer, on the processor, with any brain, server-hosted ones too.
  - Without it, memories are matched by words as before.
{{action:open-settings}}
- **Reset a companion.** The Danger zone has "Reset <name>": they forget every chat, memory and reminder but keep their name, personality and folder. One confirmation, by typing a sentence with their name.
- **Logs.**
  - Settings → Logs shows what your companion's browser, web searches, thoughts, tool calls, replies and drawing (prompt, tags, LoRAs, seed) did.
  - Turn logs off or pick which kinds to keep.
  - They stay on your computer in the companion's database (encrypted like the chat), API keys are blanked, and the oldest lines go after 7 days, 5,000 lines or 8 MB.
  - Copy them, save them as a file, or clear them.
- **Delete a companion.**
  - Settings → General has a new Danger zone that deletes the companion you're talking to, chats and memories included.
  - You confirm twice, the second time by typing a sentence with their name exactly as shown, capitals included.
  - You can also remove their folder.
  - You then continue with another companion, or go back to setup if it was the last.
- **apt and dnf packages.**
  - On Debian, Ubuntu, Fedora and relatives, install a `.deb` or `.rpm` from a signed repository (commands at https://voxcordisai.com/#download).
  - Your system's updater keeps it current. Such a copy doesn't update itself; the update window shows the command to run.

### Fixed
- **"Exceeds the available context size" errors.**
  - A long chat, or switching to a built-in model with a shorter memory span, could make every message fail.
  - VoxCordis now leaves out the oldest messages so it always fits (rules, personality and memories stay in).
  - If a model still says it's too long, VoxCordis learns its real limit, trims a little more and asks again instead of showing an error.
- **Companion's browser stopping.**
  - After a hard close or crash with the browser open, it kept running and every later start failed.
  - VoxCordis now closes the leftover browser (or uses a fresh profile) and always closes its browser when quitting.
  - Pop-up dialogs no longer freeze a page, and a crashed page reopens instead of hanging.

## 0.3.3

### New
- **Latest button.** Scrolled up in the chat, a Latest button floats in at the bottom and takes you to the newest message.

### Changed
- **Verified releases.** Release commits are signed, so GitHub shows them as Verified.

### Fixed
- **OpenRouter models without tool support.** Some models have no provider that takes tools, and OpenRouter answered 404. VoxCordis now chats with them without tools and says so in the chat. Memory still works more simply: the companion writes a short note and VoxCordis saves it, though small models may miss it now and then.
- **Dragging the chat's scrollbar.** The chat jumped around because it only guessed its full length until every message had been seen. It now knows the real length, so the bar moves smoothly.
- **Chat opening partway up.** Coming back from a past day could leave the chat at the top of the day. It now opens at the newest message. Setting or removing a background picture no longer resets the chat, and switching tabs keeps your place.
- **Closing a picture.** A click beside a picture you're looking at closes it, not only the X.

## 0.3.2

### New
- **Settings asks before losing changes.** Leave Settings with unsaved changes and VoxCordis asks whether to save, discard or stay.

### Fixed
- **Switching tabs is quicker.** Chat, Images, Memory, Skills and Plans stay ready once opened instead of being rebuilt, so going back is instant and keeps your place. The Images gallery only loads the pictures in view.
- **Settings opens on General again.** After using the settings button in the Images tab, it kept opening on Images.
- **No more big empty replies after long thoughts.** Some models write a pile of blank lines after thinking, leaving the bubble mostly empty. Those lines are dropped, also in replies you already have.

## 0.3.1

### New
- **A VoxCordis title bar** on Windows and Linux, in the app's colours, with minimise, maximise and close.
  - Drag it to move the window, double-click to maximise.
  - Prefer your system's bar? Turn on *Use the system title bar* in **Settings → Appearance**. On KDE that brings back the Breeze bar instead of the big GTK one.
  - On Windows 11, hovering the maximise button still offers Snap Layouts.

### Changed
- **A much bigger Booru tags skill.**
  - Your companion gets the real Danbooru vocabulary for faces, eyes, hair, clothes, poses, lighting, composition and adult scenes.
  - It is split into small files read only when a picture needs them, so it fits even a small memory span.
  - If you never changed the old Booru tags skill, it is replaced on its own. If you did, *Restore starter skills* in the Skills tab brings in the new one.

### Fixed
- **Open and Save dialogs look like your system's.** On Linux they come from your desktop (KDE shows its own). On Windows they no longer use the old classic style.
- **Pickers in Settings no longer bump into each other.** Those at the end of a row line up and have room.
- **The Colorway orb fades with the theme.** Switching dark and light no longer makes it jump to the new colours before the rest of the window.
- **VoxCordis has its icon on Linux** in the system tray, Alt+Tab and taskbar (no more empty spot or generic "W"), and shows up in your app menu.

## 0.3.0

### New
- **Your companion can draw.**
  - Turn on *Let your companion draw* in **Settings → Images** and download a picture model: Stable Diffusion XL, Anima Turbo or Anima Aesthetic (anime), Animagine XL 4.0 (anime) or RealVisXL 5.0 (photos). Or add your own .safetensors model, as Civitai offers them.
  - Everything is drawn on your computer with stable-diffusion.cpp. Nothing leaves it.
  - Your companion picks the model and LoRAs for each picture, and the picture shows up in the chat a little after its reply.
  - You can draw by hand in the Images tab, with an Advanced switch for model, size, steps, guidance, seed and LoRA weights.
- **LoRAs.** Add LoRA files in Settings → Images, with a .txt note beside each for its trigger words. Your companion uses them when they suit.
- **A Booru tags skill** teaches your companion to write Danbooru-style tags for the anime models.
- **A bigger look at pictures.** Click a picture in the gallery or chat to see it whole, zoom in, or open it in your own viewer with *Show file*.
- **Tabs in a new order:** Chat, Images, Memory, Skills, Plans, Settings.
- **Draw through Invoke.** If you run InvokeAI, choose *Draw with: Invoke* in Settings → Images.
  - Your companion sees the models and LoRAs installed in Invoke (Stable Diffusion 1.5, 2 and SDXL) and picks from them.
  - Pictures come back into the chat like any other.
  - The Images tab no longer warns when Invoke isn't running.
- **Export a companion.** Companion menu (tap the name) → **Export**: one ZIP with personality, lessons, privacy rules, memories, plans, chat and folder files, laid out like a Nemini export.
  - Locked with a password by default, since the ZIP leaves the encrypted database behind. Settings and API keys never go in.
  - Bring it back with **Import a character** (Nemini or VoxCordis) when adding a companion, here or on another computer.
  - Reminders and automations come back paused.

### Changed
- **Glassy pickers.** Colorway, ready light, pokes, tasks, search service, memory span, chat format and Repeat open the same frosted menu as the companion switcher, a little more compact, with the chosen option ticked.
- **The background picture sits in the big panel on the right** only, behind the chat and other tabs. The companion card and window around it keep the colorway.
- **Close to the system tray.** "Keep running when I close the window" is now **Close to the system tray**: closing the window leaves a tray icon. Click to come back, right-click for Open and Quit.
  - Linux: shows on KDE, Cinnamon, XFCE and GNOME with the AppIndicator extension.
  - Where there is no tray, the window goes to the taskbar as before.
- **Appearance has its own Settings tab**, right after General: colorway, background picture, theme and ready light. The separate Accent picker is gone, since the colorway sets the accent.

### Fixed
- **What's new shows again after updating.** 0.2.4 went out with its notes filed as unreleased, so it showed nothing. If you are on 0.2.4, you will see its notes together with this version's.
- **The day you're on stays highlighted in the right place.** Scrolling the Days list no longer leaves the highlight stuck over the top.
- **Open-source parts in About** opens on a solid page instead of making the whole window see-through.
- **A bigger smallest window.** The window can't go below 1140×720. On short windows the portrait shrinks so the days and folder button stay in view; on narrow ones the tabs show only icons instead of being cut off.
- **Haru works in the light theme**, with dark ink instead of a pale grey that vanished on white.

## 0.2.4

### New
- **Skills.**
  - Skills teach your companion particular things, in the new **Skills** tab.
  - It comes with proofreading, weather, price watch and a morning briefing, plus an ADHD support mode you can switch on.
  - While a skill is on, your companion uses it whenever it fits.
  - Type `/` in the chat to call one yourself, like `/weather Bern` or `/proofreading` followed by your text.
  - A task in the Plans tab can call one too, such as a daily `/morning-briefing`.
- **Your own skills.** Write one in the Skills tab, or import a SKILL.md, a Markdown file, or a Claude skill (.zip or .skill). Your companion can also write one when you ask it to learn something for good; those wait for you to read and turn them on.
- **Looks.** Settings → General has ready-made looks (Twilight, Rose, Ocean, Forest, Ember, Moonlight) that change the accent and colour glows together. Your companion can pick one too.
- **Colorways.** One Colorway list, each with a glossy colour orb.
  - The six standard looks change the accent and glows.
  - The three special ones below the line recolour the whole window and panels too: Haru (monochrome, red kept to accents like the send button and selected tab), Vibecoder's (indigo) and Sakura (soft pink on deep plum).
- **Poke.**
  - After three hours with nobody writing, your companion does something on its own: sends a message, potters about with its notes, or falls into a web rabbit hole when Internet is on.
  - It pokes once and waits for you, or keeps poking while you're away if you switch that on.
  - Never in your quiet hours (11 pm to 8 am unless changed).
  - Set it up under Settings → General, below In the background.
- **A background picture.** Choose any picture to sit behind the whole app, darkened for readability, with a Darkness slider. Each companion keeps its own and can set one from its folder itself.

### Changed
- **Join the community.** About has a button to the VoxCordis Discord, for help, news and sharing companions.
- **About** shows what VoxCordis is, its version and updates, its GPL-3.0 licence, a link to the source and the open-source parts it is built from.
- **The ready light** is a big Discord-style dot on the portrait's bottom-right corner, and the VoxCordis logo moved to the companion card, freeing the top bar. Right-click the light to move it next to the name or back to the chat's top bar, or pick its place in Settings → General.

### Fixed
- **Pressing Enter right after typing keeps your last letter.** Typing fast could push the last letter into the start of the next message.
- **Typing in the chat box no longer stutters.** Holding Backspace or typing quickly lagged because the frosted blur behind the panels was redrawn for every key. The main panels now skip that blur; the background holds still, so they look the same.
- **The chat opens at your newest message**, every time you come back to it.
- **A half-written message stays** when you visit another tab and come back, pictures and files included.
- **The window can't be squeezed too small** any more.
- **Dropdown menus are solid** instead of see-through.
- **Settings tidy-up.** Quit VoxCordis sits at the very bottom of General, and the encryption key field in Privacy is a single line.

## 0.2.3

### New
- **Your companion can go online.**
  - Turn on *Settings → Internet* and it can search the web and read pages for news, weather, facts and anything current.
  - What it reads is information only, never instructions. After reading the web it can't use your computer until you write again.
  - Your own computer and home network are always off limits, and you can list sites it must never visit.
  - DuckDuckGo works without an account; Brave Search, Tavily or your own SearXNG can be used instead.
- **A browser of its own, without a window.**
  - For sites that need clicking or typing, your companion can use an invisible browser: Edge, Chrome, Chromium, Brave or Vivaldi from your computer, or a small one VoxCordis downloads once.
  - It has its own profile without your logins or history, never types into password fields, and asks before sending a form.
- **Reminders and tasks.**
  - Ask "remind me at 6 to call Mum" or "every weekday morning, check the weather for me".
  - Reminders arrive in the chat in your companion's words, with a desktop notification.
  - Tasks are jobs your companion does on its own at a time, then tells you about.
  - See, change, pause or add them in the new **Plans** tab.
  - Tasks never get to use your computer, and a daily limit keeps a server-hosted brain's bill in check.
- **Keep running in the background.** *Settings → General → Keep running when I close the window* keeps reminders and tasks going with the window closed. *Start with my computer* starts VoxCordis at login.
- **Nemini reminders and automations** come along when you import a Nemini export. They arrive paused, so you can check them in the Plans tab first.
- **Your chats and memories are encrypted.**
  - They're stored encrypted on your computer, and the data you already had was encrypted on this first start.
  - The key is kept in your keyring (or encrypted for your Windows account), so nothing changes day to day.
  - **Copy your key** from *Settings → Privacy* and keep it safe: a new computer or reset keyring will ask for it.
  - You can also make a new key there, or use your own password.
- **Your companion can see.**
  - Share pictures with the paperclip, by dragging them onto the chat, or with Ctrl+V.
  - Models that can see look at them themselves: server-hosted ones like Claude or GPT, and the new Qwen3-VL models in the list.
  - For any other model, download **Eyes** in *Settings → Brain → Sight*: a small vision model that describes each picture on your computer for your companion.
- **Share text files.** Notes, code, JSON and other text files attach the same way, and your companion reads them.
- **Free the graphics card for games.** Turn on *Settings → Brain → Free the graphics card when I'm not chatting*. After a minute without typing the model leaves graphics memory; typing loads it again.
- **What's new after updating.** The first start after an update shows what changed, including every skipped version. *Settings → About* shows it again.

{{action:open-privacy}}
{{action:open-sight}}
{{action:open-internet}}

## 0.2.0

### New
- **More than one companion.** Switch from the companion card, add another, or browse them all in a gallery.
- **Import a character** during setup, from:
  - A Nemini export (memories, chat and notes).
  - A Soulkyn link.
  - Character Card files (JSON or PNG).
  - The app can also rewrite the imported personality in the companion's own words.
- **System access**, off by default.
  - With your OK, the companion can run commands and open apps, folders, files and web addresses.
  - Every request asks first. "Always allow" applies to one exact request; programs and scripts are asked about every time.
- **Cloud brains.** OpenRouter, OpenAI and Anthropic are quick picks under Server-hosted, alongside Ollama, LM Studio and any OpenAI-compatible server.
- **Light theme.** Choose System, Light or Dark. The companion can switch it, and restyle its background and accent colour.
- **Chat tools.** Stop or retry a reply, and delete a message along with everything after it.
- **Brain settings.** Chat format and temperature are now in Brain → Advanced.

### Fixed
- Replies no longer hang or freeze the window.
- Mistral Nemo no longer forgets the conversation.
- ChatML models stop cleanly at the end of a reply.
- The companion opens folders reliably when asked in everyday words.
- The companion speaks to you by name, rather than about you.

### Security and privacy
- **Your API key** is kept in your desktop keyring on Linux, and encrypted for your account on Windows. It is no longer in plain text in the settings file; an existing key moves over automatically.
- **Chats, memories, settings and companion folders** can only be read by your user account.
- **Soulkyn sign-in:** the browser window used for importing forgets the login when it closes.
- **Updates and downloads:** model downloads are pinned to an exact version and checked against a checksum. Updates and the built-in runtime install only when their checksum matches.
- **The local model server** needs a fresh random key every time it starts.

### Known
- The Windows installer isn't code-signed yet, so SmartScreen may warn the first time you run it.
