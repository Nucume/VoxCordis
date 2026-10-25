#!/usr/bin/env bash
# Wraps the Flutter Linux bundle into an AppImage.
# Usage: packaging/linux/build-appimage.sh <bundle dir> <version> <out dir>
# The AppImage uses the host's GTK 3, which every mainstream desktop ships.
set -euo pipefail

bundle=$1
version=$2
out=$3
here=$(cd "$(dirname "$0")" && pwd)
icons="$here/../../macos/Runner/Assets.xcassets/AppIcon.appiconset"
work=$(mktemp -d)
appdir="$work/VoxCordis.AppDir"

mkdir -p "$appdir/usr/lib/voxcordis" "$appdir/usr/share/applications" \
  "$appdir/usr/share/metainfo" "$appdir/usr/share/icons/hicolor/256x256/apps"
cp -a "$bundle/." "$appdir/usr/lib/voxcordis/"
cp "$here/com.nucume.companion.desktop" "$appdir/usr/share/applications/"
cp "$here/com.nucume.companion.desktop" "$appdir/"
cp "$here/com.nucume.companion.metainfo.xml" "$appdir/usr/share/metainfo/com.nucume.companion.appdata.xml"
cp "$icons/app_icon_256.png" "$appdir/usr/share/icons/hicolor/256x256/apps/com.nucume.companion.png"
cp "$icons/app_icon_256.png" "$appdir/com.nucume.companion.png"
cp "$icons/app_icon_256.png" "$appdir/.DirIcon"

cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
exec "$here/usr/lib/voxcordis/companion" "$@"
RUN
chmod +x "$appdir/AppRun"

# A fixed appimagetool, checked: its runtime ends up inside every AppImage
# we publish.
tool="$work/appimagetool"
curl -fsSL -o "$tool" \
  https://github.com/AppImage/appimagetool/releases/download/1.9.0/appimagetool-x86_64.AppImage
echo "46fdd785094c7f6e545b61afcfb0f3d98d8eab243f644b4b17698c01d06083d1  $tool" | sha256sum -c -
chmod +x "$tool"

mkdir -p "$out"
# No FUSE on CI runners, so let appimagetool unpack itself.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 VERSION="$version" \
  "$tool" --no-appstream "$appdir" "$out/VoxCordis-$version-x86_64.AppImage"
rm -rf "$work"
