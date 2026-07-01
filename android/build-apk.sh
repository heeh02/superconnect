#!/bin/zsh
# Build + install the Android receiver APK WITHOUT Gradle — for quick on-device iteration when you
# only have the Android SDK + Android Studio's bundled Kotlin compiler (no gradle/wrapper). The app has
# NO external deps (just the local :protocol sources + the Android framework), so a manual
# kotlinc → d8 → aapt2 → sign → adb install pipeline works. For a normal build use Android Studio.
#
# Usage:  android/build-apk.sh [--no-install]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"            # android/
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
STUDIO="/Applications/Android Studio.app/Contents"
export JAVA_HOME="${JAVA_HOME:-$STUDIO/jbr/Contents/Home}"
KOTLINC="$STUDIO/plugins/Kotlin/kotlinc/bin/kotlinc"
KSTDLIB="$STUDIO/plugins/Kotlin/kotlinc/lib/kotlin-stdlib.jar"

# Pick the newest installed build-tools + platform android.jar.
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
AJAR="$(ls "$SDK/platforms"/*/android.jar | sort -V | tail -1)"
ADB="$SDK/platform-tools/adb"
for f in "$KOTLINC" "$KSTDLIB" "$AJAR" "$BT/aapt2" "$BT/d8" "$BT/zipalign" "$BT/apksigner"; do
  [ -e "$f" ] || { echo "✗ missing tool: $f"; exit 1; }
done
echo "▸ SDK=$SDK  build-tools=$(basename "$BT")  platform=$(basename "$(dirname "$AJAR")")"

OUT="${TMPDIR:-/tmp}/sc-apk"; rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/dex"

echo "1/6 kotlinc → classes"
SRCS=$(find "$HERE/protocol/src/main/kotlin" "$HERE/app/src/main/kotlin" -name '*.kt')
"$KOTLINC" -cp "$AJAR" -jvm-target 17 -d "$OUT/classes" ${=SRCS}

echo "2/6 d8 → classes.dex (+ kotlin-stdlib)"
CLS=$(find "$OUT/classes" -name '*.class')
"$BT/d8" --min-api 24 --lib "$AJAR" --output "$OUT/dex" ${=CLS} "$KSTDLIB"

echo "3/6 aapt2 compile+link → base.apk"
sed 's#<manifest xmlns:android="http://schemas.android.com/apk/res/android">#<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.superconnect.receiver">#' \
  "$HERE/app/src/main/AndroidManifest.xml" > "$OUT/AndroidManifest.xml"
# Compile app resources (res/ — e.g. drawable/ic_launcher) to .flat, then link with -R so the manifest's
# @drawable/... references resolve. (Was missing → aapt2 "resource ic_launcher not found" once kotlinc
# stopped failing first; Android Studio/Gradle does this compile step for you.)
RES_FLAGS=()
if [ -d "$HERE/app/src/main/res" ]; then
  "$BT/aapt2" compile --dir "$HERE/app/src/main/res" -o "$OUT/res.zip"
  RES_FLAGS=(-R "$OUT/res.zip" --auto-add-overlay)
fi
"$BT/aapt2" link -o "$OUT/base.apk" -I "$AJAR" --manifest "$OUT/AndroidManifest.xml" \
  "${RES_FLAGS[@]}" \
  --min-sdk-version 24 --target-sdk-version 36 --version-code 2 --version-name 0.2.0

echo "4/6 add classes.dex"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
( cd "$OUT/dex" && zip -q -j "$OUT/unsigned.apk" classes.dex )

echo "5/6 zipalign + sign (debug key)"
"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
KS="$HOME/.android/debug.keystore"
[ -f "$KS" ] || { mkdir -p "$HOME/.android"; "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KS" \
  -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1; }
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$HERE/app-debug.apk" "$OUT/aligned.apk"
echo "✓ built $HERE/app-debug.apk"

if [[ "$1" != "--no-install" ]]; then
  echo "6/6 adb install (approve 'Install via USB' on the phone if prompted)"
  "$ADB" install -r "$HERE/app-debug.apk"
fi
