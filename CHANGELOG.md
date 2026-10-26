# Changelog

VoxCordis shows these notes the first time it starts after an update,
including every version that was skipped on the way. Each `## x.y.z` heading
is one version. While a version is being worked on its notes go under
`## Unreleased`; rename that heading to the version when tagging it.

A line of its own like `{{action:open-settings}}` becomes a button under
that version's notes (see `lib/features/update/whats_new_dialog.dart` for
the ids); it is left out of the release page.

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
