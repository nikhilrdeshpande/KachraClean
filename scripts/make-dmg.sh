#!/bin/sh
# Packages build/KachraClean.app into a drag-to-Applications disk image:
# build/KachraClean-<version>.dmg. Run scripts/build-app.sh first (UNIVERSAL=1 for releases).
set -e
cd "$(dirname "$0")/.."
APP=build/KachraClean.app
[ -d "$APP" ] || { echo "Missing $APP; run scripts/build-app.sh first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/KachraClean-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "KachraClean $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
shasum -a 256 "$DMG"
echo "Built $DMG"
