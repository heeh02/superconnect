# Release signing (Android receiver)

The release APK is signed with a **stable keystore** so it installs cleanly on any device, updates in
place, and is distributable. This is the Android analogue of the Mac app's stable self‑signed cert.

> The debug keystore (`~/.android/debug.keystore`) is **per‑machine** — rebuilding elsewhere yields a
> different signature, so users can't update in place. Never ship debug‑signed.

## What's gitignored (never committed)
- `android/release.keystore` — the signing key.
- `android/keystore.properties` — its paths + passwords.

Both are listed in `android/.gitignore`. **Back up the keystore securely** — if you lose it you can no
longer publish updates that existing installs will accept.

## Bootstrap (once)
```bash
cd android
keytool -genkeypair -v -keystore release.keystore -alias superconnect \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass '<your-store-pass>' -keypass '<your-key-pass>' \
  -dname "CN=Superconnect, O=Superconnect, C=CN"

cat > keystore.properties <<EOF
storeFile=release.keystore
storePassword=<your-store-pass>
keyAlias=superconnect
keyPassword=<your-key-pass>
EOF
```

`app/build.gradle.kts` reads `keystore.properties` automatically: when present, `release` builds are
signed with it; when **absent** (fresh clone / CI without the secret), release falls back to the debug
signature so the project still builds.

## Build a distributable APK
```bash
./gradlew :app:assembleRelease     # or: gradle :app:assembleRelease
# → app/build/outputs/apk/release/app-release.apk  (universal, signed, installable on Android 7+)
```

Bump `versionCode` (and `versionName`) in `app/build.gradle.kts` for each release so in‑place updates work.
