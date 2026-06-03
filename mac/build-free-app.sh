#!/bin/zsh
# Build the FREE Mac host as a SEPARATE app — "superconnect_free" — with its own bundle id + Desktop
# path, so it NEVER collides with the mainline Superconnect.app (which is developed in parallel for
# paid features). This is the free/open-core host: HarmonyOS (hdc) + Android (adb) wired + wireless,
# no paid features. Built from the `dev` branch. Output: ~/Desktop/superconnect_free.app
#
# One-time on first launch: grant Screen Recording + Accessibility to "superconnect_free" in System
# Settings (it's a distinct bundle id, so it has its own grants — separate from the mainline app).
cd "$(dirname "$0")"
SC_APP_NAME="superconnect_free" \
SC_BUNDLE_ID="com.superconnect.free" \
SC_APP_PATH="$HOME/Desktop/superconnect_free.app" \
  ./build-app.sh "$@"
