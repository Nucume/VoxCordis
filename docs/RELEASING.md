# Releasing VoxCordis

Releases are built and signed by the maintainer's CI in the development
repository, which then publishes each version's source and installers to the
public repository. The workflows described here are not part of the public
source; you can build everything yourself as shown in the README.

Two workflows live in `.github/workflows/`:

- **CI** (`ci.yml`): `flutter analyze` and `flutter test` on every pull request
  and every push to `main`. Linux runner only.
- **Release** (`release.yml`): builds the installers. It runs when a `v*` tag is
  pushed, when started by hand (Actions → Release → Run workflow), and on pull
  requests that change the packaging.

| Platform | File | Built with |
| --- | --- | --- |
| Windows | `VoxCordis-<v>-windows-x64-setup.exe` | Inno Setup, per-user install by default, no admin needed |
| Linux | `VoxCordis-<v>-x86_64.AppImage` | `appimagetool`, uses the system GTK 3 (and WebKitGTK 4.1 when installed) |

macOS (`.dmg`) and Flatpak are not built for now. Their scripts stay in
`packaging/macos` and `packaging/flatpak`.

Nothing large is bundled: the llama.cpp runtime and models are downloaded by
the app on first use into the app-support directory.

## Cutting a release

1. Bump `version:` in `pubspec.yaml` (optional; the tag wins for file names).
2. Check that `## Unreleased` in `CHANGELOG.md` says what's new. Those notes
   become the release page, and the app shows them on its first start after
   updating, together with the notes of any version the user skipped. There
   is no need to rename the heading: after the release is published, the
   workflow's `changelog` job files them under `## <version>` on main (notes
   merged after the tag stay under Unreleased). Renaming it yourself before
   tagging works too.
3. Add a `<release>` line to `packaging/linux/com.nucume.companion.metainfo.xml`.
4. Tag and push:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

The Release workflow builds everything and creates a GitHub Release with the
two files attached. A tag with a dash (`v0.2.0-beta.1`) becomes a pre-release.

Manual runs and pull request runs keep the files as workflow artifacts (on the
run's summary page) instead of making a release.

## In-app updates

The app checks `releases/latest` of a GitHub repository a few seconds after
it starts (and from *Settings → About*). When the release is newer than the
running build, a pill in the top bar offers *Update to x.y.z*:

- **AppImage**: the new AppImage is downloaded next to the running one,
  replaces it and is started; the old process exits.
- **Windows**: the setup `.exe` is downloaded to the temp folder and run with
  `/SILENT /update=1`; the installer starts the app again when it is done.
- Anything else (a plain bundle, a dev build) gets a link to the release page.

Pre-releases (tags with a dash) are skipped. Builds know their version from
`--dart-define=APP_VERSION`, which this workflow sets from the tag; test
builds are `<pubspec version>-dev.<run>`, which counts as older than the
release of the same number.

**The release repository has to be public.** GitHub hides releases of a
private repository from everyone without access, so the update check sees
nothing. Either make this repository public, or keep the code private and
publish releases to a separate public repository:

1. Create the public repository (e.g. `Nucume/VoxCordis`) with at least one
   commit (a README), because a release needs a commit to tag.
2. Add a fine-grained token with *Contents: read and write* on that repository
   as the secret `RELEASES_TOKEN`.
3. Add the repository variable `UPDATE_REPO` = `Nucume/VoxCordis`.

Tags then still go to this repository, and the workflow publishes the release
(and bakes `UPDATE_REPO` into the app) to the public one.

**The source goes public with each release.** Before publishing, the release
job replaces the public repository's files with this tag's source and commits
it as one commit, "VoxCordis x.y.z", authored by Nucume. The release tags that
commit, so every release's source is right next to it (GPL-3.0). This
repository's history, pull requests and reviews stay private. Workflows are
left out, so nothing runs on the public repository's tags.

## Installing unsigned builds

Until the builds are signed:

- **Windows** shows SmartScreen ("Windows protected your PC"): *More info →
  Run anyway*.
- **AppImage**: `chmod +x VoxCordis-*.AppImage` and run it.

## Release signing (required for a release)

Every installer a release publishes gets a `<file>.sig`: an Ed25519
signature over the file's SHA-256 (64 lowercase hex characters). The app
has the matching public key built in (`releasePublicKey` in
`lib/services/release_signature.dart`) and the updater installs only files
that carry a valid signature. Without it, anyone holding `RELEASES_TOKEN`
could publish an update every user would install.

One-time setup, on your own computer:

```sh
openssl genpkey -algorithm ed25519 -out voxcordis-release.pem
openssl pkey -in voxcordis-release.pem -pubout   # the public key
```

1. Save the whole content of `voxcordis-release.pem` as the repository
   secret `RELEASE_SIGNING_KEY`, then keep the file offline (a password
   manager or a USB stick). Losing it means the next version has to ship a
   new key, which installed apps won't trust, so their users update once by
   hand.
2. Paste the public key into `releasePublicKey`.

A tag fails to publish when the secret is missing or the app has no key.

## Signing (optional, add secrets to turn on)

The signing steps are skipped while their secrets are missing. Add them under
*Settings → Secrets and variables → Actions*.

**macOS** (needs a paid Apple Developer Program membership):

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | base64 of the exported *Developer ID Application* `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` password |
| `MACOS_SIGNING_IDENTITY` | e.g. `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | 10-character team id |
| `APPLE_APP_PASSWORD` | an app-specific password for that Apple ID |

**Windows**:

| Secret | Value |
| --- | --- |
| `WINDOWS_CERTIFICATE` | base64 of a code-signing `.pfx` |
| `WINDOWS_CERTIFICATE_PASSWORD` | the `.pfx` password |

Many certificate vendors now ship keys only on hardware tokens or in a cloud
HSM, which a `.pfx` secret cannot use. Azure Trusted Signing is the cheapest
cloud option; switching to it means replacing the `signtool` steps with
`azure/trusted-signing-action`.

## Flathub (later)

The `.flatpak` file installs anywhere, but showing up in GNOME Software and
KDE Discover needs a Flathub listing. Flathub requires:

- an app id on a domain or code host you can prove you own. `com.nucume.companion`
  would need `nucume.com`; `io.github.nucume.VoxCordis` works with the GitHub
  account. Changing the id touches `linux/CMakeLists.txt`, the macOS bundle
  id and these packaging files.
- a manifest that builds from source (Flutter SDK as a module, pub packages
  vendored as sources) instead of wrapping the CI bundle,
- a public source repository, screenshots and a full metainfo file.

## Cost

On a private repository Actions minutes are billed past the plan's monthly
allowance, and Windows minutes count 2x. A Release run is roughly 10 Linux
and 15 Windows minutes, which counts as about 40 minutes. CI alone is a few Linux minutes per push.

## Privacy check

CI fails when a word from the secret `PRIVATE_NAMES` (comma-separated, e.g.
real names) appears in any file or in any commit's author, committer or
message. The words stay in the secret, so the check never adds them to the
repository. Without the secret the step is skipped.
