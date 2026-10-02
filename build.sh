#!/bin/bash
# Builds RTSPOverlay and creates build/RTSPOverlay.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/RTSPOverlay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# strip -x: removes debug symbols (~670 KB → ~380 KB)
strip -x .build/release/RTSPOverlay -o "$APP/Contents/MacOS/RTSPOverlay"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Created $APP ($(du -sh "$APP" | cut -f1))"
echo "To install: cp -R $APP /Applications/"
