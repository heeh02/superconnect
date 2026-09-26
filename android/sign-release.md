# Release signing boundary (FOSS Android receiver)

The separate package is `com.superconnect.receiver.foss`. The explicitly labelled v0.2.1
open-source prerelease may ship an Android Debug-signed APK. This exception is not a stable release
signing policy; later stable releases need an authorized, recoverable signer.

> The debug keystore (`~/.android/debug.keystore`) is **per-machine**. The v0.2.1 prerelease must
> publish the exact APK certificate SHA-256. A later APK signed with a different key cannot update
> that installation in place; uninstalling it can remove app-local pairing and data. Do not use
> debug signing for Standard or a stable release.

## What's gitignored (never committed)
- `android/release.keystore` — the signing key.
- `android/keystore.properties` — its paths + passwords.

Both are listed in `android/.gitignore`. **Back up the keystore securely** — if you lose it you can no
longer publish updates that existing installs will accept.

## Future stable signer

The authorized release owner must create and back up a stable keystore outside Git, use hidden
interactive password input or an approved secret manager, and verify the public certificate
fingerprint before packaging. Never put passwords in shell command arguments, heredocs, scripts,
logs, or committed files. The v0.2.1 debug-signed preview does not require this step.

`app/build.gradle.kts` reads `keystore.properties` automatically. Debug builds do not require release
credentials. Release builds fail before packaging when the properties file, any required field, or the
configured keystore is missing; they never fall back to the debug signature.

The focused boundary check does not read signing secrets:
```bash
bash check-release-signing.sh
```

With Gradle/JDK/Android SDK available, a fresh checkout can also exercise the expected negative path:
```bash
gradle --no-daemon :app:validateReleaseSigning
# expected without local release credentials: release_signing_properties_missing
```

## Build a future stable-release APK
```bash
./gradlew :app:assembleRelease     # or: gradle :app:assembleRelease
# → app/build/outputs/apk/release/app-release.apk  (arm64-v8a, only after release authorization)
```

Bump `versionCode` (and `versionName`) in `app/build.gradle.kts` for each release so in‑place updates work.
