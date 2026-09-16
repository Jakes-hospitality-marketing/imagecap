#!/bin/bash
# Cut a new ImageCap release: bump the version, build, zip, and publish.
#
#   ./release.sh 1.1
#
# Publishes to GitHub if the `gh` CLI is installed and authenticated. Otherwise it
# builds the zip and prints what to upload by hand.

set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "Usage: ./release.sh <version>    e.g. ./release.sh 1.1"
  echo "Current: $(cat VERSION 2>/dev/null || echo 'none')"
  exit 1
fi

echo "$VERSION" > VERSION

echo "Building $VERSION…"
./build.sh

ZIP="build/ImageCap.zip"
rm -f "$ZIP"
# ditto writes the archive format macOS expects, preserving the bundle's symlinks.
ditto -c -k --sequesterRsrc --keepParent "build/ImageCap.app" "$ZIP"
echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1))"

# A .pkg is the format MDM systems deploy. Strip AppleDouble files first so
# the payload does not carry ._ resource-fork stubs.
PKG="build/ImageCap.pkg"
rm -f "$PKG"
dot_clean -m "build/ImageCap.app" 2>/dev/null || true
pkgbuild --component "build/ImageCap.app" \
         --install-location /Applications \
         --identifier com.imagecap.app \
         --version "$VERSION" \
         "$PKG" >/dev/null
echo "Packaged $PKG ($(du -h "$PKG" | cut -f1)) — this is the file an MDM system deploys"

git add -A
git commit -q -m "Release $VERSION" || echo "(nothing new to commit)"
git tag -f "v$VERSION"

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo "Publishing to GitHub…"
  git push -q origin HEAD --tags
  gh release create "v$VERSION" "$ZIP" "$PKG" \
    --title "ImageCap $VERSION" \
    --notes "Run or re-run the installer to update:
\`\`\`
curl -fsSL https://raw.githubusercontent.com/\$(gh repo view --json nameWithOwner -q .nameWithOwner)/main/install.sh | bash
\`\`\`"
  echo "Released v$VERSION."
else
  cat <<EOF

Built, tagged, and committed locally — but 'gh' is not installed, so publish by hand:

  1. git push origin HEAD --tags
  2. Open your repo on github.com → Releases → "Draft a new release"
  3. Choose the existing tag v$VERSION
  4. Attach both:
       $(pwd)/$ZIP
       $(pwd)/$PKG
  5. Publish

Your team updates by reopening ImageCap and clicking the update banner.
To deploy it through an MDM system instead, hand IT: $(pwd)/$PKG
EOF
fi
