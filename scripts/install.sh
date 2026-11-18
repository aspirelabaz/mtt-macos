#!/bin/zsh
# Build MTT (Release), install it to /Applications and restart it.
# Usage: scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/../App"

xcodegen generate >/dev/null
xcodebuild -project MTT.xcodeproj -scheme MTT -configuration Release \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

APP=build/DerivedData/Build/Products/Release/MTT.app
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }

# Stop the running copy (launchd agent) and its Finder extension, then swap the app.
pkill -x MTT || true
pkill -f MTTFileProvider || true
sleep 1
rm -rf /Applications/MTT.app
# Bump the bundle's date: macOS caches app icons by bundle path + modification
# date, and Xcode never updates the .app folder's own date (the Dock kept
# showing a stale generic icon).
touch "$APP"
ditto "$APP" /Applications/MTT.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MTT.app

# Opening it hands over to launchd (see App/MTT/Service/Agent.swift).
open /Applications/MTT.app
echo "Installed /Applications/MTT.app"
