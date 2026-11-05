#!/bin/bash
# Builds Shrink.app and installs it to ~/Applications.
#
# ~/Applications needs no admin rights, and an app compiled locally never gets
# the com.apple.quarantine flag that makes Gatekeeper block downloaded apps —
# which is why this runs on a machine where HandBrake.app cannot be installed.
set -euo pipefail

cd "$(dirname "$0")"

# shellcheck source=release.conf
source ./release.conf

APP_NAME="Shrink"
DEST="${1:-$HOME/Applications}"
APP="$DEST/$APP_NAME.app"

# Releases are git tags (v1.2.0). CI passes the tag in; a local build reports
# the latest tag it contains, so it is only offered releases made after it.
VERSION="${SHRINK_VERSION:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# "-" is an ad-hoc signature, fine for running on this Mac. The release
# workflow passes a Developer ID identity so the build can be notarised.
SIGN_IDENTITY="${SHRINK_SIGN_IDENTITY:--}"

echo "==> Building release binary"
swift build -c release

# A running instance keeps its old executable mapped in memory, so replacing
# the bundle on disk changes nothing until the app is restarted. Quitting here
# stops a stale window from quietly serving up the previous build.
RUNNING_PID="$(pgrep -x "$APP_NAME" || true)"
if [ -n "$RUNNING_PID" ] && ps -o comm= -p "$RUNNING_PID" | grep -q "^$APP/"; then
  echo "==> Quitting running $APP_NAME"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.25
  done
  pgrep -x "$APP_NAME" >/dev/null && echo "    (still running — close it by hand)" || true
fi

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
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>ShrinkUpdateRepository</key><string>$REPOSITORY</string>
  <key>ShrinkUpdateTeamID</key><string>$TEAM_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <!-- Alternate rank: offered in Open With and accepted on the Dock icon,
         but never taken over as the default app for these files. -->
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>org.matroska.mkv</string>
        <string>org.webmproject.webm</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
  $ICON_ENTRY
</dict>
</plist>
PLIST

# arm64 refuses to run unsigned code, and signing the assembled bundle keeps
# the signature covering the final Info.plist.
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "==> Signing (ad-hoc)"
  codesign --force --sign - "$APP" >/dev/null 2>&1
else
  # Notarisation requires the hardened runtime and a secure timestamp.
  echo "==> Signing as $SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi

echo "==> Done: $APP ($VERSION, build $BUILD_NUMBER)"
echo "    Launch it with: open -a $APP_NAME"
