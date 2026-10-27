#!/usr/bin/env bash
# Wraps the Flutter Linux bundle into a .deb and an .rpm.
# Usage: packaging/linux/build-packages.sh <bundle dir> <version> <out dir>
#
# Both install the app to /usr/lib/voxcordis (the same layout as the
# AppImage), with /usr/bin/voxcordis, the menu entry, the icon and the
# AppStream file. The .rpm is signed later, by the release job, because the
# signing key lives there (see build-repo.sh). Needs dpkg-deb and rpmbuild.
set -euo pipefail

bundle=$(cd "$1" && pwd)
version=$2
out=$3
here=$(cd "$(dirname "$0")" && pwd)
root="$here/../.."
icons="$root/macos/Runner/Assets.xcassets/AppIcon.appiconset"
maintainer='Nucume <119841008+Nucume@users.noreply.github.com>'
home=https://github.com/Nucume/VoxCordis
summary='A private AI companion that runs on your computer'
blurb='VoxCordis chats with a local language model it runs itself, keeps its
files in a folder you choose, and remembers things in a memory you can read,
edit, pin and forget.'

# 0.3.3-dev.12 sorts before 0.3.3 only with a tilde.
pkgver=${version/-/\~}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
out=$(cd "$out" && pwd)

# The files as they are installed, relative to /.
tree="$work/tree"
mkdir -p "$tree/usr/lib/voxcordis" "$tree/usr/bin" \
  "$tree/usr/share/applications" "$tree/usr/share/metainfo" \
  "$tree/usr/share/icons/hicolor/256x256/apps"
cp -a "$bundle/." "$tree/usr/lib/voxcordis/"
cp "$here/com.nucume.companion.desktop" "$tree/usr/share/applications/"
cp "$here/com.nucume.companion.metainfo.xml" "$tree/usr/share/metainfo/"
cp "$icons/app_icon_256.png" \
  "$tree/usr/share/icons/hicolor/256x256/apps/com.nucume.companion.png"
ln -s ../lib/voxcordis/companion "$tree/usr/bin/voxcordis"
chmod -R u+rwX,go+rX,go-w "$tree"
size_kb=$(du -sk "$tree" | cut -f1)

# ---- .deb ----------------------------------------------------------------
deb="$work/deb"
cp -a "$tree" "$deb"
# package-type tells the app a package manager owns this copy, so it points
# there for updates instead of replacing itself (lib/services/updater.dart).
echo deb > "$deb/usr/lib/voxcordis/package-type"
mkdir -p "$deb/usr/share/doc/voxcordis" "$deb/DEBIAN"
cp "$root/LICENSE" "$deb/usr/share/doc/voxcordis/copyright"
chmod 644 "$deb/usr/lib/voxcordis/package-type" "$deb/usr/share/doc/voxcordis/copyright"
cat > "$deb/DEBIAN/control" <<EOF
Package: voxcordis
Version: $pkgver
Architecture: amd64
Maintainer: $maintainer
Installed-Size: $size_kb
Depends: libc6 (>= 2.35), libstdc++6, liblzma5, libgtk-3-0 | libgtk-3-0t64
Recommends: libwebkit2gtk-4.1-0
Section: net
Priority: optional
Homepage: $home
Description: $summary
$(printf '%s\n' "$blurb" | sed 's/^/ /')
 .
 libwebkit2gtk-4.1 is only needed for the sign-in windows of character
 importers.
EOF
dpkg-deb --root-owner-group --build "$deb" "$out/voxcordis_${pkgver}_amd64.deb" >/dev/null

# ---- .rpm ----------------------------------------------------------------
# Stripping would break the app's AOT library, and the bundled libraries are
# not for other packages to depend on, so both are switched off.
rpmtop="$work/rpm"
mkdir -p "$rpmtop"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
rpmroot="$work/rpmroot"
cp -a "$tree" "$rpmroot"
echo rpm > "$rpmroot/usr/lib/voxcordis/package-type"
chmod 644 "$rpmroot/usr/lib/voxcordis/package-type"
mkdir -p "$rpmroot/usr/share/licenses/voxcordis"
cp "$root/LICENSE" "$rpmroot/usr/share/licenses/voxcordis/LICENSE"
chmod 644 "$rpmroot/usr/share/licenses/voxcordis/LICENSE"
cat > "$rpmtop/SPECS/voxcordis.spec" <<EOF
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none
AutoReqProv: no

Name:       voxcordis
Version:    $pkgver
Release:    1
Summary:    $summary
License:    GPL-3.0-or-later
URL:        $home
Packager:   $maintainer
BuildArch:  x86_64
Requires:   glibc >= 2.35
Requires:   gtk3
Requires:   xz-libs
Requires:   libstdc++
Recommends: webkit2gtk4.1

%description
$blurb

%install
mkdir -p %{buildroot}
cp -a $rpmroot/. %{buildroot}/

%files
/usr/bin/voxcordis
/usr/lib/voxcordis
/usr/share/applications/com.nucume.companion.desktop
/usr/share/metainfo/com.nucume.companion.metainfo.xml
/usr/share/icons/hicolor/256x256/apps/com.nucume.companion.png
%license /usr/share/licenses/voxcordis/LICENSE
EOF
rpmbuild -bb --quiet --define "_topdir $rpmtop" --target x86_64 \
  "$rpmtop/SPECS/voxcordis.spec"
cp "$rpmtop"/RPMS/x86_64/voxcordis-*.rpm "$out/"
ls -la "$out"
