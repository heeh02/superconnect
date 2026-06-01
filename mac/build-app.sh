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

DIST=0
[[ "$1" == "--dist" ]] && DIST=1   # also emit a shareable Superconnect.app.zip

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

echo "▸ compiling (release, universal arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64 --product superconnect-app

APP="$HOME/Desktop/Superconnect.app"
echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Universal multi-arch build lands under .build/apple/Products/Release (not .build/release).
cp .build/apple/Products/Release/superconnect-app "$APP/Contents/MacOS/superconnect-app"
echo "▸ app binary archs: $(lipo -archs "$APP/Contents/MacOS/superconnect-app" 2>/dev/null || echo '?')"
cp app/Info.plist "$APP/Contents/Info.plist"
cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # constellation icon (matches the tablet)

# Bundle hdc (+ its libusb) so the app is SELF-CONTAINED — the user needs NO DevEco install.
# hdc's rpath is @loader_path/. so libusb_shared.dylib must sit right next to it.
HDC_SRC=""
for d in \
  "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains" \
  "/Applications/DevEco-Studio.app/Contents/tools/hdc" \
  "$HOME/command-line-tools/sdk/default/openharmony/toolchains"; do
  [ -x "$d/hdc" ] && { HDC_SRC="$d"; break; }
done
if [ -n "$HDC_SRC" ]; then
  mkdir -p "$APP/Contents/Resources/hdc"
  cp "$HDC_SRC/hdc" "$APP/Contents/Resources/hdc/"
  [ -f "$HDC_SRC/libusb_shared.dylib" ] && cp "$HDC_SRC/libusb_shared.dylib" "$APP/Contents/Resources/hdc/"
  HDC_ARCHS="$(lipo -archs "$APP/Contents/Resources/hdc/hdc" 2>/dev/null || echo '?')"
  echo "▸ bundled hdc + libusb from $HDC_SRC (archs: $HDC_ARCHS)"
  case "$HDC_ARCHS" in
    *x86_64*) ;;  # universal/Intel hdc → self-contained on Intel too
    *) echo "   ⚠️  hdc is arm64-only — on INTEL Macs the app runs (universal binary) but falls back to a"
       echo "       system hdc (DevEco / HarmonyOS Command Line Tools). To make Intel self-contained too,"
       echo "       drop an x86_64 hdc beside this one and lipo-merge into a universal hdc." ;;
  esac
else
  echo "⚠️  hdc NOT found on this build machine — the app will need DevEco at runtime (not self-contained)"
fi

# Sign with the stable self-signed cert → TCC grants (Screen Recording / Accessibility) persist.
# --deep signs the bundled hdc + libusb too.
codesign --force --deep --sign "$CN" --keychain "$KC" "$APP"

echo "✓ built $APP (signed: $CN)"
echo "  Grant Screen Recording + Accessibility ONCE; the grant now sticks across rebuilds."

if [[ $DIST == 1 ]]; then
  echo "▸ packaging shareable zip…"
  ( cd "$HOME/Desktop" && rm -f Superconnect.app.zip && ditto -c -k --keepParent "Superconnect.app" "Superconnect.app.zip" )
  echo "✓ $HOME/Desktop/Superconnect.app.zip"
  echo "  Share this zip. First open on another Mac: right-click the app → 打开 (Open) → 打开,"
  echo "  or run:  xattr -dr com.apple.quarantine /Applications/Superconnect.app"
fi
