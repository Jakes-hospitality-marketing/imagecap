#!/bin/bash
# Builds ImageCap.app. Requires only the Xcode Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")"

APP="ImageCap"
VERSION="$(cat VERSION 2>/dev/null || echo 1.0)"
BUILD_DIR="build"
BUNDLE="$BUILD_DIR/$APP.app"
MACOS_DIR="$BUNDLE/Contents/MacOS"
RES_DIR="$BUNDLE/Contents/Resources"

rm -rf "$BUNDLE"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "Compiling…"
# swiftc builds one architecture at a time, so compile each and lipo them together.
# That way the same .app runs on both Apple Silicon and Intel Macs.
SLICES=()
for arch in arm64 x86_64; do
  out="$BUILD_DIR/$APP-$arch"
  if xcrun --sdk macosx swiftc \
      -O -whole-module-optimization \
      -target "$arch-apple-macos13.0" \
      -parse-as-library \
      -o "$out" \
      Sources/ImageCap/*.swift 2>"$BUILD_DIR/$arch.log"; then
    SLICES+=("$out")
    echo "  $arch ok"
  else
    echo "  $arch unavailable (skipped)"
  fi
done

if [ ${#SLICES[@]} -eq 0 ]; then
  echo "Build failed:"; cat "$BUILD_DIR"/*.log; exit 1
fi

if [ ${#SLICES[@]} -gt 1 ]; then
  lipo -create "${SLICES[@]}" -output "$MACOS_DIR/$APP"
else
  cp "${SLICES[0]}" "$MACOS_DIR/$APP"
fi
rm -f "${SLICES[@]}"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>com.imagecap.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Jake Rosanno</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

if [ -f "AppIcon.icns" ]; then
  cp AppIcon.icns "$RES_DIR/AppIcon.icns"
fi

# An ad-hoc signature is what lets the app open after the user approves it once.
# Without any signature at all, recent macOS refuses to launch it outright.
codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || echo "note: ad-hoc signing unavailable"

echo "Built $BUNDLE"
du -sh "$BUNDLE" | awk '{print "Size: " $1}'
