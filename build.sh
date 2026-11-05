#!/bin/bash
# Builds Shrink.app and installs it to ~/Applications.
#
# ~/Applications needs no admin rights, and an app compiled locally never gets
# the com.apple.quarantine flag that makes Gatekeeper block downloaded apps —
# which is why this runs on a machine where HandBrake.app cannot be installed.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Shrink"
BUNDLE_ID="com.mpuskac.shrink"
VERSION="1.0"
DEST="${1:-$HOME/Applications}"
APP="$DEST/$APP_NAME.app"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_ENTRY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  ICON_ENTRY=""
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  $ICON_ENTRY
</dict>
</plist>
PLIST

# Ad-hoc signature: arm64 refuses to run unsigned binaries, and re-signing the
# assembled bundle keeps the signature covering the final Info.plist.
echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "==> Done: $APP"
echo "    Launch it with: open -a $APP_NAME"
