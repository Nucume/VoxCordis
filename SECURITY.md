# Security Policy

VoxCordis runs language models on your computer and, when you allow it, can
run commands for its companion. Security reports are very welcome.

## Supported versions

Only the newest release gets security fixes. Older versions are not
patched, so please update before you report a problem. The app can update
itself in one click from Settings.

| Version         | Supported |
| --------------- | --------- |
| Latest release  | Yes       |
| Anything older  | No        |

## Reporting a vulnerability

Please do **not** open a public issue for a security problem. Report it
privately through GitHub instead: on
[Nucume/VoxCordis](https://github.com/Nucume/VoxCordis), open
**Security → Report a vulnerability**
([direct link](https://github.com/Nucume/VoxCordis/security/advisories/new)).
Only you and the maintainer can see the report.

Please include:

- what you found and what an attacker could do with it,
- steps to reproduce it, or a proof of concept,
- the VoxCordis version (Settings → About) and your operating system.

You can expect a reply **within 24 hours**. Once the problem is
confirmed, the fix ships in a regular update, and installed apps pick it up
in one click. Tell me if you'd like credit in the release notes.

## Scope

In scope:

- the app itself: the updater, downloads of the runtime and models, the
  companion's file and system tools, imports, and how secrets and data are
  stored.

Out of scope (please report these to their own projects):

- problems inside llama.cpp or another bundled runtime,
- the models themselves,
- a server-hosted brain you connect to (OpenRouter, OpenAI, Anthropic,
  Ollama, LM Studio and so on).

## How releases are protected

Every installer is published with a SHA-256 checksum and an Ed25519
signature. The app checks both before it installs an update. The public key
is in `lib/services/release_signature.dart`.

## Disclaimer

VoxCordis is provided **as is**, without warranty of any kind, express or
implied, as set out in sections 15 and 16 of the GNU General Public License
v3 ([LICENSE](LICENSE)). Security reports are handled on a best-effort
basis, and no guarantee is made that a reported issue will be fixed by a
particular date.
