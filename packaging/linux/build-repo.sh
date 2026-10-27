#!/usr/bin/env bash
# Builds the signed apt and dnf repository that serves VoxCordis' .deb and
# .rpm, as plain files for GitHub Pages.
#
# Usage: packaging/linux/build-repo.sh <new packages dir> <repo dir>
#
# <repo dir> is the repo/ folder of the site as it is now (it may be empty or
# missing); the new packages are added to it, the oldest versions beyond the
# newest KEEP (default 3) are dropped, and the metadata is made again and
# signed. Needs a GnuPG home with the signing key (GNUPGHOME, KEY_FPR) and
# BASE_URL, the address <repo dir> is served from. Tools: apt-ftparchive
# (apt-utils), createrepo_c, rpm, gpg.
set -euo pipefail

new=$(cd "$1" && pwd)
mkdir -p "$2"
repo=$(cd "$2" && pwd)
: "${GNUPGHOME:?}" "${KEY_FPR:?}" "${BASE_URL:?}"
keep=${KEEP:-3}
base=${BASE_URL%/}
sign=(gpg --batch --yes --pinentry-mode loopback --local-user "$KEY_FPR")

# Newest KEEP files of a pattern in a folder stay; the rest go.
prune() { # dir glob
  local f
  (cd "$1" && ls -1 $2 2>/dev/null | sort -V | head -n -"$keep") | while read -r f; do
    rm -f "$1/$f"
  done
}

# ---- the key --------------------------------------------------------------
"${sign[@]}" --armor --export "$KEY_FPR" > "$repo/voxcordis.asc"
"${sign[@]}" --export "$KEY_FPR" > "$repo/voxcordis.gpg"

# ---- apt ------------------------------------------------------------------
pool="$repo/apt/pool/main"
dist="$repo/apt/dists/stable"
mkdir -p "$pool" "$dist/main/binary-amd64"
cp "$new"/*.deb "$pool/"
prune "$pool" '*.deb'
(
  cd "$repo/apt"
  apt-ftparchive packages pool/main > dists/stable/main/binary-amd64/Packages
  gzip -9nk -f dists/stable/main/binary-amd64/Packages
  xz -9 -k -f dists/stable/main/binary-amd64/Packages
  rm -f dists/stable/Release dists/stable/InRelease dists/stable/Release.gpg
)
rel=$(mktemp)
(cd "$repo/apt" && apt-ftparchive \
  -o APT::FTPArchive::Release::Origin=VoxCordis \
  -o APT::FTPArchive::Release::Label=VoxCordis \
  -o APT::FTPArchive::Release::Suite=stable \
  -o APT::FTPArchive::Release::Codename=stable \
  -o APT::FTPArchive::Release::Architectures=amd64 \
  -o APT::FTPArchive::Release::Components=main \
  release dists/stable) > "$rel"
mv "$rel" "$dist/Release"
"${sign[@]}" --clearsign -o "$dist/InRelease" "$dist/Release"
"${sign[@]}" --armor --detach-sign -o "$dist/Release.gpg" "$dist/Release"

# ---- dnf ------------------------------------------------------------------
rpms="$repo/rpm"
mkdir -p "$rpms"
cp "$new"/*.rpm "$rpms/"
prune "$rpms" '*.rpm'
# Every package in the repository has to carry our signature.
check=$(mktemp -d)
rpm --dbpath "$check" --import "$repo/voxcordis.asc"
for f in "$rpms"/*.rpm; do
  rpm --dbpath "$check" -K "$f" | grep -q 'signatures OK' \
    || { echo "::error::$(basename "$f") is not signed with the package key."; exit 1; }
done
rm -rf "$check"
rm -rf "$rpms/repodata"
createrepo_c --quiet "$rpms"
"${sign[@]}" --armor --detach-sign -o "$rpms/repodata/repomd.xml.asc" "$rpms/repodata/repomd.xml"
cat > "$rpms/voxcordis.repo" <<EOF
[voxcordis]
name=VoxCordis
baseurl=$base/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$base/voxcordis.asc
EOF

# ---- the page -------------------------------------------------------------
latest=$(ls -1 "$pool" | sed -n 's/^voxcordis_\(.*\)_amd64\.deb$/\1/p' | sort -V | tail -n 1)
cat > "$repo/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>VoxCordis for apt and dnf</title>
<style>
  :root { color-scheme: light dark; --bg: #fbf9f7; --fg: #26211f; --muted: #6f6762; --card: #fff; --line: #e4ddd8; --accent: #b4456b; }
  @media (prefers-color-scheme: dark) { :root { --bg: #17131a; --fg: #ece6ea; --muted: #a399a3; --card: #211b25; --line: #352d3a; --accent: #e07aa0; } }
  body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.55 system-ui, sans-serif; }
  main { max-width: 46rem; margin: 0 auto; padding: 3rem 1rem 4rem; }
  h1 { font-size: 1.9rem; margin: 0 0 .25rem; } h2 { font-size: 1.15rem; margin: 2.2rem 0 .5rem; }
  p { margin: .4rem 0; } .muted { color: var(--muted); } a { color: var(--accent); }
  pre { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: .9rem 1rem; overflow-x: auto; font-size: .86rem; line-height: 1.5; }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
</style>
</head>
<body>
<main>
<h1>VoxCordis for apt and dnf</h1>
<p class="muted">Version ${latest:-?}. Updates arrive through your package manager like any other package. The repository and every package in it are signed.</p>

<h2>Debian, Ubuntu, Mint and relatives (apt)</h2>
<pre><code>sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL $base/voxcordis.gpg | sudo tee /etc/apt/keyrings/voxcordis.gpg &gt;/dev/null
echo "deb [signed-by=/etc/apt/keyrings/voxcordis.gpg] $base/apt stable main" | sudo tee /etc/apt/sources.list.d/voxcordis.list
sudo apt update
sudo apt install voxcordis</code></pre>

<h2>Fedora and relatives (dnf)</h2>
<pre><code>sudo curl -fsSL -o /etc/yum.repos.d/voxcordis.repo $base/rpm/voxcordis.repo
sudo dnf install voxcordis</code></pre>

<h2>Good to know</h2>
<p>64-bit x86 only, glibc 2.35 or newer (Ubuntu 22.04, Debian 12, Fedora 36 and later). The key's fingerprint is <code>$KEY_FPR</code>; the key itself is <a href="voxcordis.asc">voxcordis.asc</a>.</p>
<p>Installed this way, VoxCordis does not update itself; it tells you when a new version is out and the command to run. Prefer a single file? The AppImage and the Windows installer are on the <a href="https://github.com/Nucume/VoxCordis/releases">releases page</a>.</p>
</main>
</body>
</html>
EOF
