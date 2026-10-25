#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DisplaySwitch.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -fobjc-arc -O2 -Wall -Wextra -Wno-deprecated-declarations \
  -mmacosx-version-min=13.0 \
  -framework Cocoa -framework CoreGraphics -framework ServiceManagement \
  -o "$APP/Contents/MacOS/DisplaySwitch" \
  "$ROOT/src/main.m" "$ROOT/src/DisplayCatalog.m" "$ROOT/src/SpaceTracker.m"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
