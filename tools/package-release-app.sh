#!/bin/zsh
# Build + sign + pack the HarmonyOS RELEASE App Pack (.app) for AppGallery upload.
#
# Why this exists: hvigor's built-in signing requires DevEco-ENCRYPTED passwords in
# build-profile.json5 (can't be produced outside the DevEco GUI). This script bypasses that
# by signing the HAP directly with the official `hap-sign-tool` (plaintext password), then
# assembling the .app with `app_packing_tool` — so build-profile.json5 stays clean (no certs,
# keys, or passwords ever committed) and packaging works fully from the command line.
#
# Prerequisites (one-time, see README / earlier setup):
#   $SC_SIGN_DIR (default ~/superconnect-release) contains:
#     superconnect.p12              keystore (private key; EC P-256)
#     superconnect.cer              release certificate from AppGallery Connect
#     superconnectRelease.p7b       release profile from AppGallery Connect (bound to the bundle)
#   export SC_KEYSTORE_PW='...'     the keystore password
#
# Usage:
#   SC_KEYSTORE_PW='<your-keystore-password>' tools/package-release-app.sh
# Output: $SC_SIGN_DIR/Superconnect.app  → upload this to AppGallery Connect.
set -e

DEVECO="/Applications/DevEco-Studio.app/Contents"
SDK="$DEVECO/sdk/default/openharmony/toolchains/lib"
JAVA="$DEVECO/jbr/Contents/Home/bin/java"
export JAVA_HOME="$DEVECO/jbr/Contents/Home"
export DEVECO_SDK_HOME="$DEVECO/sdk"
export PATH="$DEVECO/tools/node/bin:$PATH"
HV="$DEVECO/tools/hvigor/bin/hvigorw"

HARMONY_DIR="$(cd "$(dirname "$0")/../harmony" && pwd)"
SIGN_DIR="${SC_SIGN_DIR:-$HOME/superconnect-release}"
PW="${SC_KEYSTORE_PW:?set SC_KEYSTORE_PW to your keystore password}"
ALIAS="${SC_KEY_ALIAS:-superconnect}"
OUT="$SIGN_DIR/Superconnect.app"
OUTDIR="entry/build/default/outputs/default"
UNSIGNED="$OUTDIR/entry-default-unsigned.hap"
SIGNED="$OUTDIR/entry-default-signed.hap"

for f in superconnect.p12 superconnect.cer superconnectRelease.p7b; do
  [ -f "$SIGN_DIR/$f" ] || { echo "✗ missing signing material: $SIGN_DIR/$f"; exit 1; }
done

cd "$HARMONY_DIR"
echo "▸ building unsigned HAP (release)…"
rm -f "$UNSIGNED" "$SIGNED"
# build-profile.json5 has signingConfigs:[] → hvigor's SignHap step no-ops/fails; we only need the
# unsigned HAP it produces just before that, then sign it ourselves below.
"$HV" --no-daemon assembleHap -p product=default -p buildMode=release >/dev/null 2>&1 || true
[ -f "$UNSIGNED" ] || { echo "✗ unsigned HAP not produced — check the build (run hvigorw assembleHap manually)"; exit 1; }

echo "▸ signing HAP (hap-sign-tool, plaintext pw + code signing)…"
# HarmonyOS NEXT requires a code-signing block (-signCode 1) and -compatibleVersion is REQUIRED
# for a HAP; without them AppGallery rejects the package as "非法软件包" (error 991). Derive the
# compatible API from build-profile.json5's compatibleSdkVersion, e.g. "6.1.0(23)" → 23.
COMPAT=$(grep compatibleSdkVersion build-profile.json5 | grep -oE '\([0-9]+\)' | tr -d '()')
[ -n "$COMPAT" ] || { echo "✗ could not derive compatibleVersion from build-profile.json5"; exit 1; }
"$JAVA" -jar "$SDK/hap-sign-tool.jar" sign-app -mode localSign -keyAlias "$ALIAS" -keyPwd "$PW" \
  -appCertFile "$SIGN_DIR/superconnect.cer" -profileFile "$SIGN_DIR/superconnectRelease.p7b" \
  -inFile "$UNSIGNED" -signAlg SHA256withECDSA -keystoreFile "$SIGN_DIR/superconnect.p12" \
  -keystorePwd "$PW" -outFile "$SIGNED" -profileSigned 1 -signCode 1 -compatibleVersion "$COMPAT" >/dev/null

echo "▸ assembling App Pack (.app)…"
"$JAVA" -jar "$SDK/app_packing_tool.jar" --mode app --hap-path "$SIGNED" \
  --pack-info-path "$OUTDIR/pack.info" --out-path "$OUT" --force true >/dev/null

echo "▸ verifying signature…"
"$JAVA" -jar "$SDK/hap-sign-tool.jar" verify-app -inFile "$SIGNED" \
  -outCertChain /tmp/sc-cc.cer -outProfile /tmp/sc-pp.p7b 2>&1 | grep -qi "verify success" \
  && echo "✓ $OUT  →  upload this to AppGallery Connect" \
  || { echo "✗ signature verification FAILED"; exit 1; }
