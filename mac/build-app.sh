#!/bin/zsh
# Build Superconnect.app — a double-clickable menu-bar app bundle wrapping the
# produce host. Output: ~/Desktop/Superconnect.app
set -e
cd "$(dirname "$0")"

echo "▸ compiling (release)…"
swift build -c release --product superconnect-app

APP="$HOME/Desktop/Superconnect.app"
echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/superconnect-app "$APP/Contents/MacOS/superconnect-app"
cp app/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc sign so the bundle has a stable identity for TCC (Screen Recording /
# Accessibility) permissions across launches.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✓ built $APP"
echo "  Double-click it; grant Screen Recording + Accessibility on first run."
