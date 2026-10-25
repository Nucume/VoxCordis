#!/usr/bin/env bash
# Packs VoxCordis.app into a drag-to-Applications disk image.
# Usage: packaging/macos/build-dmg.sh <path to VoxCordis.app> <out .dmg>
set -euo pipefail

app=$1
dmg=$2
stage=$(mktemp -d)

cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
mkdir -p "$(dirname "$dmg")"
hdiutil create -volname VoxCordis -srcfolder "$stage" -ov -format UDZO "$dmg"
rm -rf "$stage"
