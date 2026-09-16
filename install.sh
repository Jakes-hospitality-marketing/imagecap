#!/bin/bash
# ImageCap installer / updater.
#
# Run with:
#   curl -fsSL https://raw.githubusercontent.com/Jakes-hospitality-marketing/imagecap/main/install.sh | bash
#
# Downloads the latest release and installs it to /Applications.
#
# Why this exists rather than "download the .dmg and double-click": the app is ad-hoc
# signed, not notarized, so anything downloaded by a *browser* gets tagged with
# com.apple.quarantine and macOS 15+ refuses to open it without a trip through
# System Settings → Privacy & Security. Files fetched by curl carry no such tag, so
# installing this way means the app just opens. Re-run this to update.

set -euo pipefail

REPO="Jakes-hospitality-marketing/imagecap"
APP="ImageCap"
DEST="/Applications/$APP.app"

echo "Looking up the latest $APP release…"
API="https://api.github.com/repos/$REPO/releases/latest"
ZIP_URL=$(curl -fsSL "$API" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)

if [ -z "$ZIP_URL" ]; then
  echo "Could not find a .zip asset on the latest release of $REPO."
  echo "Check that a release exists and has $APP.zip attached."
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Downloading…"
curl -fsSL -o "$TMP/$APP.zip" "$ZIP_URL"

echo "Unpacking…"
ditto -x -k "$TMP/$APP.zip" "$TMP"

NEW=$(find "$TMP" -maxdepth 2 -name "*.app" -type d | head -1)
if [ -z "$NEW" ]; then
  echo "The download did not contain an app."
  exit 1
fi

# Close it if it is running, so the bundle can be replaced cleanly.
if pgrep -x "$APP" >/dev/null 2>&1; then
  echo "Quitting the running copy…"
  osascript -e "quit app \"$APP\"" >/dev/null 2>&1 || true
  sleep 1
fi

echo "Installing to $DEST…"
rm -rf "$DEST"
cp -R "$NEW" "$DEST"

VERSION=$(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
echo
echo "$APP $VERSION installed."
echo "Opening it now — you'll find it in Applications from here on."
open "$DEST"
