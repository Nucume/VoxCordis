# Releasing VoxCordis

A tag in the development repository checks the release, then sends that
version's source and the tag to the public repository, whose own workflow
builds, signs and publishes the installers. The development repository's
workflows are not part of the public source; you can build everything yourself
as shown in the README.

Workflows in the development repository (`.github/workflows/`):

- **CI** (`ci.yml`): `flutter analyze` and `flutter test` on every pull request
  and every push to `main` (skipped when only docs change; can be started by
  hand). Linux runner only.
- **Release** (`release.yml`): checks a `v*` tag (version, release key,
  privacy) and pushes the source commit and the tag to the public repository.
  It builds nothing. A hand run only does the checks.

Workflow in the public repository (`Nucume/VoxCordis`, `release.yml`):

- **Release**: runs when the tag arrives. It builds the installers, signs them
  and publishes the GitHub Release. Free there. A hand run (Actions → Release →
  Run workflow) builds Linux only unless you pick `all` or `windows`, and keeps
  the files as artifacts without making a release. Pull requests do not start
  it, so test a packaging change with a hand run.

| Platform | File | Built with |
| --- | --- | --- |
| Windows | `VoxCordis-<v>-windows-x64-setup.exe` | Inno Setup, per-user install by default, no admin needed |
| Linux | `VoxCordis-<v>-x86_64.AppImage` | `appimagetool`, uses the system GTK 3 (and WebKitGTK 4.1 when installed) |
| Debian, Ubuntu | `voxcordis_<v>_amd64.deb` | `dpkg-deb` (`packaging/linux/build-packages.sh`) |
| Fedora | `voxcordis-<v>-1.x86_64.rpm` | `rpmbuild`, signed with the package key |

macOS (`.dmg`) and Flatpak are not built for now. Their scripts stay in
`packaging/macos` and `packaging/flatpak`.

Nothing large is bundled: the llama.cpp runtime and models are downloaded by
the app on first use into the app-support directory.

## The apt and dnf repository

A stable tag (no dash) also updates a signed apt and dnf repository that is
served from GitHub Pages at `https://voxcordisai.com/repo/` (the site's custom
domain, read from `CNAME` on `gh-pages`). The
public `release` job builds it (`packaging/linux/build-repo.sh`) after the
GitHub Release exists, keeps the newest three versions, and puts the result
into the `repo/` folder of the `gh-pages` branch (one commit, so old packages
don't pile up in git history). Everything else on that branch is the website
and is left alone. Pre-releases never reach the repository.

One-time setup:

1. Settings → Pages in the public repository: *Deploy from a branch*,
   `gh-pages`, `/ (root)`.
2. Create the package key on your own computer (RSA, because older rpm
   versions can't check newer key types), with no passphrase so CI can use
   it. The user ID is public, so keep it to Nucume:

   ```sh
   export GNUPGHOME=$(mktemp -d)
   gpg --batch --passphrase '' --quick-gen-key \
     'VoxCordis Packages <119841008+Nucume@users.noreply.github.com>' \
     rsa4096 sign never
   gpg --armor --export-secret-keys 'VoxCordis Packages'
   ```

   Save the printed block (including the BEGIN and END lines) as the secret
   `PACKAGE_SIGNING_KEY` in the public repository's `release` environment.
   Keep an offline copy: losing it means every user has to import a new key.
   Users trust the key through `voxcordis.asc` / `voxcordis.gpg` in `repo/`,
   which the job derives from the secret.

A tag fails to publish when the secret is missing.

Installed from the repository, the app doesn't update itself: the package
carries a `package-type` file next to the program, the updater sees it and
shows the apt or dnf command instead of downloading anything.

## Cutting a release

1. Bump `version:` in `pubspec.yaml` (optional; the tag wins for file names).
2. Check that `## Unreleased` in `CHANGELOG.md` says what's new. Those notes
   become the release page, and the app shows them on its first start after
   updating, together with the notes of any version the user skipped. There
   is no need to rename the heading: after the source is pushed, the
   workflow's `changelog` job files them under `## <version>` on main (notes
   merged after the tag stay under Unreleased). Renaming it yourself before
   tagging works too.
3. Add a `<release>` line to `packaging/linux/com.nucume.companion.metainfo.xml`.
4. Tag and push:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

The tag starts the private checks; the public repository then builds
everything and creates a GitHub Release with the two files attached, after you
approve the `release` environment there. A tag with a dash (`v0.2.0-beta.1`)
becomes a pre-release.

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
2. Create an SSH key pair, add the public half to the public repository as a
   deploy key with write access, and save the private half here as the secret
   `PUBLIC_DEPLOY_KEY`. Add *Deploy keys* to the bypass list of the public
   repository's rulesets for `main` and for `v*` tags, so only the pipeline
   can create release tags.
3. Add the repository variable `UPDATE_REPO` = `Nucume/VoxCordis`.
4. In the public repository, create the environment `release` (required
   reviewer: the maintainer, deployment tags: `v*`) and save the secret
   `RELEASE_SIGNING_KEY` in it, not as a repository secret.

Tags then still go to this repository; the pipeline pushes the source and the
tag to the public one, which builds the app with itself as its update source.

**The source goes public with each release.** Before the tag is pushed, the
release job replaces the public repository's files with this tag's source and commits
it as one commit, "VoxCordis x.y.z", authored by Nucume. The release tags that
commit, so every release's source is right next to it (GPL-3.0). This
repository's history, pull requests and reviews stay private. Workflows are
left out; the public repository keeps its own `release.yml`, which runs on
the tag that comes with the commit.

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
that carry a valid signature. Without it, anyone who can publish to the public
repository could ship an update every user would install.

One-time setup, on your own computer:

```sh
openssl genpkey -algorithm ed25519 -out voxcordis-release.pem
openssl pkey -in voxcordis-release.pem -pubout   # the public key
```

1. Save the whole content of `voxcordis-release.pem` as the secret
   `RELEASE_SIGNING_KEY` in the public repository's `release` environment, then keep the file offline (a password
   manager or a USB stick). Losing it means the next version has to ship a
   new key, which installed apps won't trust, so their users update once by
   hand.
2. Paste the public key into `releasePublicKey`.

A tag fails to publish when the secret is missing or the app has no key.

## Signing (optional, add secrets to turn on)

Code signing is off. The public workflow no longer has the Windows signing
steps (the macOS ones are not built), so these tables are for adding them
back later.

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

Builds run on the public repository, where Actions minutes are free. Here, on
a private repository, minutes are billed past the plan's monthly allowance and
Windows counts 2x: a tag costs a few Linux minutes for the checks and the
source push, and CI is a few Linux minutes per push (none for docs-only
changes).

## Privacy check

CI fails when a word from the secret `PRIVATE_NAMES` (comma-separated, e.g.
real names) appears in any file or in any commit's author, committer or
message. The words stay in the secret, so the check never adds them to the
repository. Without the secret the step is skipped.
