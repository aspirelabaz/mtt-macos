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
ditto "$APP" /Applications/MTT.app

# Opening it hands over to launchd (see App/MTT/Service/Agent.swift).
open /Applications/MTT.app
echo "Installed /Applications/MTT.app"
