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

# App identity is overridable so a SEPARATE build (e.g. the free `superconnect_free`) can coexist with
# the mainline Superconnect.app — distinct name + bundle id + path → its own TCC grants, no collision.
APP_NAME="${SC_APP_NAME:-Superconnect}"
BUNDLE_ID="${SC_BUNDLE_ID:-com.superconnect.mac}"
APP="${SC_APP_PATH:-$HOME/Desktop/$APP_NAME.app}"
echo "▸ assembling $APP (name=$APP_NAME id=$BUNDLE_ID)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Universal multi-arch build lands under .build/apple/Products/Release (not .build/release).
cp .build/apple/Products/Release/superconnect-app "$APP/Contents/MacOS/superconnect-app"
echo "▸ app binary archs: $(lipo -archs "$APP/Contents/MacOS/superconnect-app" 2>/dev/null || echo '?')"
# Patch CFBundleName/DisplayName (exact `<string>Superconnect</string>`) + bundle id from the template.
sed -e "s#<string>Superconnect</string>#<string>$APP_NAME</string>#g" \
    -e "s#com.superconnect.mac#$BUNDLE_ID#g" \
    app/Info.plist > "$APP/Contents/Info.plist"
cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # constellation icon (matches the tablet)

# Bundle hdc (+ its libusb) so the app is SELF-CONTAINED — the user needs NO DevEco install.
# Per-arch layout (Resources/hdc/<arch>/): each slice of the universal app loads hdc from its own
# arch dir, since an arm64 hdc can't run on Intel and vice-versa. A future x86_64 hdc is a drop-in
# under hdc/x86_64/. hdc's rpath is @loader_path/. so libusb_shared.dylib sits beside it in each dir.
HDC_SRC=""
for d in \
  "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains" \
  "/Applications/DevEco-Studio.app/Contents/tools/hdc" \
  "$HOME/command-line-tools/sdk/default/openharmony/toolchains"; do
  [ -x "$d/hdc" ] && { HDC_SRC="$d"; break; }
done
if [ -n "$HDC_SRC" ]; then
  HDC_ARCHS="$(lipo -archs "$HDC_SRC/hdc" 2>/dev/null || echo 'arm64')"
  for arch in arm64 x86_64; do
    case "$HDC_ARCHS" in
      *"$arch"*)
        mkdir -p "$APP/Contents/Resources/hdc/$arch"
        cp "$HDC_SRC/hdc" "$APP/Contents/Resources/hdc/$arch/"
        [ -f "$HDC_SRC/libusb_shared.dylib" ] && cp "$HDC_SRC/libusb_shared.dylib" "$APP/Contents/Resources/hdc/$arch/"
        ;;
    esac
  done
  echo "▸ bundled hdc + libusb from $HDC_SRC (archs: $HDC_ARCHS) → Resources/hdc/<arch>/"
  case "$HDC_ARCHS" in
    *x86_64*) ;;  # universal/Intel hdc → self-contained on Intel too
    *) echo "   ⚠️  bundled hdc is arm64-only — on INTEL Macs the app runs (universal binary) but falls"
       echo "       back to a system hdc (DevEco / HarmonyOS Command Line Tools). To make Intel"
       echo "       self-contained, drop an x86_64 (or universal) hdc into Resources/hdc/x86_64/." ;;
  esac
else
  echo "⚠️  hdc NOT found on this build machine — the app will need DevEco at runtime (not self-contained)"
fi

# Bundle adb (Android wired bridge) so Android tablets work self-contained too. Google's platform-tools
# adb is a UNIVERSAL macOS binary (arm64+x86_64) and freely redistributable, so a single flat copy at
# Resources/adb/adb serves both arches (AdbTool looks there first, then a system adb).
ADB_SRC=""
for a in \
  "$HOME/Library/Android/sdk/platform-tools/adb" \
  "/opt/homebrew/bin/adb" "/usr/local/bin/adb" "$(command -v adb 2>/dev/null)"; do
  [ -x "$a" ] && { ADB_SRC="$a"; break; }
done
if [ -n "$ADB_SRC" ]; then
  mkdir -p "$APP/Contents/Resources/adb"
  cp "$ADB_SRC" "$APP/Contents/Resources/adb/adb"
  echo "▸ bundled adb from $ADB_SRC (archs: $(lipo -archs "$ADB_SRC" 2>/dev/null || echo '?')) → Resources/adb/"
else
  echo "ℹ️  adb NOT found — Android-wired needs a system adb at runtime (install Android platform-tools)."
  echo "    Wireless to Android works without adb; drop platform-tools' adb into Resources/adb/ to self-contain."
fi

# Sign with the stable self-signed cert → TCC grants (Screen Recording / Accessibility) persist.
# --deep signs the bundled hdc/adb + libusb too.
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
