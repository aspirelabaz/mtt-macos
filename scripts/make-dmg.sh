#!/bin/zsh
# Build MTT (Release) and package it as a drag-to-install DMG in dist/.
# Usage: scripts/make-dmg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/App"

xcodegen generate >/dev/null
xcodebuild -project MTT.xcodeproj -scheme MTT -configuration Release \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

APP="$ROOT/App/build/DerivedData/Build/Products/Release/MTT.app"
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUT="$ROOT/dist/MTT-$VERSION.dmg"
STAGE="$(mktemp -d)"
mkdir -p "$ROOT/dist"

# Window contents: the app and a shortcut to /Applications.
touch "$APP"  # fresh bundle date, so the icon isn't taken from an old cache
ditto "$APP" "$STAGE/MTT.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -quiet -volname "MTT $VERSION" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$OUT" 2>/dev/null
rm -rf "$STAGE"

# Sign the image with the same identity as the app.
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)$/\1/p' | head -1)
[[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$OUT"

hdiutil verify "$OUT" >/dev/null
echo "Created $OUT ($(du -h "$OUT" | cut -f1))"
