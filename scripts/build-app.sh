#!/bin/sh
# Builds KachraClean.app into ./build without Xcode: SwiftPM release build, then a minimal bundle
# with Info.plist, the resource bundle in Contents/Resources, and an ad-hoc code signature.
set -e
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP=build/KachraClean.app

swift build -c release --product KachraCleanApp
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/KachraCleanApp" "$APP/Contents/MacOS/KachraClean"
cp -R "$BIN/KachraClean_KachraCore.bundle" "$APP/Contents/Resources/"
if [ -f Assets/AppIcon.icns ]; then cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>KachraClean</string>
  <key>CFBundleDisplayName</key><string>KachraClean</string>
  <key>CFBundleIdentifier</key><string>io.github.nikhilrdeshpande.KachraClean</string>
  <key>CFBundleExecutable</key><string>KachraClean</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
