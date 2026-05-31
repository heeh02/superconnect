#!/bin/zsh
# Build Superconnect.app — a double-clickable windowed app (device dashboard + menu-bar
# quick-access) hosting the screencast. Output: ~/Desktop/Superconnect.app
#
# Signs with a STABLE self-signed certificate (bootstrapped on first run into a dedicated
# keychain). This is what makes macOS keep the Screen Recording / Accessibility grants across
# rebuilds — ad-hoc signing (codesign -s -) re-prompts on every launch. The keychain password
# below guards only a throwaway local code-signing cert (no security value; safe to be public).
set -e
cd "$(dirname "$0")"

KC="$HOME/Library/Keychains/superconnect-signing.keychain-db"
KCPASS="superconnect-dev"
CN="Superconnect Self-Signed"

if ! security find-certificate -c "$CN" "$KC" >/dev/null 2>&1; then
  echo "▸ bootstrapping self-signed signing cert ($CN)…"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/sck.pem -out /tmp/scc.pem -days 3650 \
    -subj "/CN=$CN" -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
  openssl pkcs12 -export -inkey /tmp/sck.pem -in /tmp/scc.pem -out /tmp/sc.p12 -passout "pass:$KCPASS" -name "$CN" >/dev/null 2>&1
  security create-keychain -p "$KCPASS" "$KC" 2>/dev/null || true
  security set-keychain-settings "$KC"
  security unlock-keychain -p "$KCPASS" "$KC"
  security list-keychains -d user -s $(security list-keychains -d user | sed 's/"//g' | tr '\n' ' ') "$KC"
  security import /tmp/sc.p12 -k "$KC" -P "$KCPASS" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null 2>&1
  rm -f /tmp/sck.pem /tmp/scc.pem /tmp/sc.p12
fi
security unlock-keychain -p "$KCPASS" "$KC" 2>/dev/null || true

echo "▸ compiling (release)…"
swift build -c release --product superconnect-app

APP="$HOME/Desktop/Superconnect.app"
echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/superconnect-app "$APP/Contents/MacOS/superconnect-app"
cp app/Info.plist "$APP/Contents/Info.plist"
cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # constellation icon (matches the tablet)

# Sign with the stable self-signed cert → TCC grants (Screen Recording / Accessibility) persist.
codesign --force --deep --sign "$CN" --keychain "$KC" "$APP"

echo "✓ built $APP (signed: $CN)"
echo "  Grant Screen Recording + Accessibility ONCE; the grant now sticks across rebuilds."
