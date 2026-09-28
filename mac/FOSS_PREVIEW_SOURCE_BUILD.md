# Build the v0.2.2 Mac FOSS Preview from source

This document describes the Mac source for the v0.2.2 FOSS successor. Public v0.2.1 remains
immutable. v0.2.2 adds consent-gated right-click/scroll/zoom input and visible 25/50/80 Mbps
quality presets; the release page binds its reviewed source, Core and downloadable artifacts.

The Mac product built by this tree is:

- app name: Superconnect FOSS Preview
- bundle ID: com.superconnect.foss.preview
- version/build: 0.2.2 / 5
- direction: Mac source to Android receiver
- input policy: opt-in touch, pen and keyboard; injection requires app consent and Accessibility
- current validated Mac architecture: Apple silicon (arm64)

com.superconnect.foss.preview is a new identity. It neither upgrades nor imports credentials,
defaults, or Screen Recording consent from the historical com.superconnect.free app.

## Compatibility break from public v0.2.0

The public v0.2.0 Mac binary uses the legacy handshake and plaintext application-record path. The
v0.2.1 and v0.2.2 receivers require SC-AUTH-v1 plus SC-RECORD-v1 before VIDEO or CONTROL is
admitted. Therefore the old v0.2.0 Mac binary cannot cast to these secure receivers. This is an intentional
fail-closed protocol boundary, not an in-place update path.

Keep an installed v0.2.0 app untouched if it is still needed. Build and test v0.2.2 under the new
bundle identity. Do not copy the old pairing secret or claim that its TCC grant migrates.

## Evidence boundary

The commands below prove that one exact clean Git commit builds the canonical Rust Core, the
Mac sender with optional tablet control, and its local tests. They do not prove Developer ID signing, notarization,
Store acceptance, or physical-tablet behavior.

An ordinary distribution still needs Developer ID signing and notarization. For this explicitly
experimental FOSS prerelease only, the integration owner may package the exact reviewed
Apple Development-signed arm64 app after source-to-artifact and physical-pair acceptance. The ZIP
must disclose Gatekeeper rejection, no notarization and no stable signing/update guarantee.

GitHub Actions are not part of this build. Run the commands on a trusted Apple-silicon Mac with a
full Xcode installation.

## 1. Select and record the exact source

Clone the public repository and check out the exact reviewed v0.2.2 release commit. Do
not build from a private worktree, a dirty checkout, or a source archive with no Git identity.

From the repository root:

Run sections 1 through 5 in the same zsh session so the SC_FOSS variables remain bound to one
candidate.

    set -euo pipefail

    SC_FOSS_SOURCE_SHA="$(git rev-parse HEAD)"
    SC_FOSS_SOURCE_TREE="$(git rev-parse 'HEAD^{tree}')"
    [[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]]

    print -- "sourceGitSha=$SC_FOSS_SOURCE_SHA"
    print -- "sourceTreeSha=$SC_FOSS_SOURCE_TREE"

Retain both values with the build evidence. The released source tag and published instructions
must resolve to the same commit.

## 2. Record the Apple and Rust toolchains

Rust is pinned by rust-toolchain.toml to 1.97.1. Apple SDK/Xcode bytes are externally provisioned,
so their exact identity must be recorded for each candidate.

Set the full Xcode path installed on the builder:

    set -euo pipefail

    SC_FOSS_XCODE_DIR="/Applications/Xcode.app/Contents/Developer"
    [[ -d "$SC_FOSS_XCODE_DIR" && ! -L "$SC_FOSS_XCODE_DIR" ]]

    DEVELOPER_DIR="$SC_FOSS_XCODE_DIR" /usr/bin/xcodebuild -version
    DEVELOPER_DIR="$SC_FOSS_XCODE_DIR" /usr/bin/xcrun swift --version
    DEVELOPER_DIR="$SC_FOSS_XCODE_DIR" /usr/bin/xcrun --sdk macosx --show-sdk-version
    rustup run 1.97.1 rustc -Vv

If Xcode lives elsewhere, change only SC_FOSS_XCODE_DIR. CommandLineTools alone are insufficient
for the XCTest run.

## 3. Build the canonical Core from the same clean commit

Keep Core outputs outside the checkout so the clean-source receipt is not affected by build files:

    set -euo pipefail

    SC_FOSS_ROOT="$(pwd -P)"
    SC_FOSS_BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sc-foss-mac-build.XXXXXX")"
    SC_FOSS_CORE_OUTPUT="$SC_FOSS_BUILD_ROOT/core-ffi"
    SC_FOSS_CARGO_OUTPUT="$SC_FOSS_BUILD_ROOT/core-cargo"

    DEVELOPER_DIR="$SC_FOSS_XCODE_DIR" \
    SC_CORE_FFI_OUTPUT_ROOT="$SC_FOSS_CORE_OUTPUT" \
    SC_CORE_CARGO_TARGET_DIR="$SC_FOSS_CARGO_OUTPUT" \
      "$SC_FOSS_ROOT/tools/build-core-ffi.sh" \
        --target aarch64-apple-darwin \
        --profile ffi-release \
        --variant full

    SC_FOSS_CORE_DIR="$SC_FOSS_CORE_OUTPUT/aarch64-apple-darwin/ffi-release"

This builds libsuperconnect_core.a, its ABI manifest, and core-ffi-receipt-v1.json. No opaque
prebuilt Core archive is an acceptable substitute.

Verify that the receipt still binds the current clean checkout:

    set -euo pipefail

    python3 "$SC_FOSS_ROOT/tools/core_ffi_receipt.py" verify \
      --archive "$SC_FOSS_CORE_DIR/libsuperconnect_core.a" \
      --abi-manifest "$SC_FOSS_CORE_DIR/core-abi-manifest-v1.json" \
      --target aarch64-apple-darwin \
      --profile ffi-release \
      --variant full \
      --receipt "$SC_FOSS_CORE_DIR/core-ffi-receipt-v1.json" \
      --require-clean

    shasum -a 256 \
      "$SC_FOSS_CORE_DIR/libsuperconnect_core.a" \
      "$SC_FOSS_CORE_DIR/core-ffi-receipt-v1.json"

## 4. Build the free Mac sender

The free SwiftPM product links only the canonical Core, Mac capture/encode effects, the bounded
consent-gated FOSS input injector and the free application composition. It excludes the broader
commercial product/runtime modules.

    set -euo pipefail

    DEVELOPER_DIR="$SC_FOSS_XCODE_DIR" \
    SC_MAC_CORE_FFI_LIBRARY_PATH="$SC_FOSS_CORE_DIR" \
      "$SC_FOSS_ROOT/mac/build-free-app.sh" -c release

    SC_FOSS_BIN_DIR="$(
      DEVELOPER_DIR="$SC_FOSS_XCODE_DIR" \
      SC_MAC_CORE_FFI_LIBRARY_PATH="$SC_FOSS_CORE_DIR" \
        /usr/bin/xcrun swift build \
          --package-path "$SC_FOSS_ROOT/mac" \
          -c release \
          --show-bin-path
    )"
    SC_FOSS_MAC_BINARY="$SC_FOSS_BIN_DIR/superconnect-app-foss-preview"

    [[ -f "$SC_FOSS_MAC_BINARY" && -x "$SC_FOSS_MAC_BINARY" ]]
    file "$SC_FOSS_MAC_BINARY"
    shasum -a 256 "$SC_FOSS_MAC_BINARY"

The resulting executable is source-build evidence. Only the integration owner's separately
reviewed, signed and checksummed package is the downloadable experimental asset.

Confirm that canonical secure-connection entry points and the consent-gated native input effects link:

    set -euo pipefail

    nm "$SC_FOSS_MAC_BINARY" |
      rg '_sc_secure_connection_(seal_frame|push)_v1'

    nm -u "$SC_FOSS_MAC_BINARY" | rg 'AXIsProcessTrusted|CGEventPost'

These OS calls are compiled for optional touch/pen/keyboard control. Viewing does not require
Accessibility. The injector rejects input unless both Accessibility and the app's explicit
tablet-control toggle are enabled; do not reset TCC or auto-grant that toggle in a build.

    plutil -lint "$SC_FOSS_ROOT/mac/app/Info.plist"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      "$SC_FOSS_ROOT/mac/app/Info.plist"

The last command must print com.superconnect.foss.preview.

## 5. Run the Mac verification suite

    set -euo pipefail

    DEVELOPER_DIR="$SC_FOSS_XCODE_DIR" \
    SC_MAC_CORE_FFI_LIBRARY_PATH="$SC_FOSS_CORE_DIR" \
      /usr/bin/xcrun swift test --package-path "$SC_FOSS_ROOT/mac"

The focused FOSS tests cover:

- Auth/Record activation before media;
- authenticated VIDEO and CONTROL on the production sender path;
- plaintext, tamper, and replay rejection;
- atomic seal-to-transport enqueue ordering for concurrent real CONTROL sends;
- Ready/failure/close cleanup of native handshake artifacts while live Record traffic continues;
- exact preview product/identity and opt-in input policy;
- canonical pen/key encoding and encrypted INPUT routing into the production callback.

Report the exact test count and failures. A passing host suite does not establish physical-tablet
decode/render behavior.

## 6. Optional owner-only local pairing app

An authorized test owner with an Apple Development identity may assemble a local app for the
physical pair-run:

    set -euo pipefail

    SC_FOSS_LOCAL_SIGNER="Apple Development: replace-with-your-identity"
    SC_FOSS_LOCAL_APP="$SC_FOSS_BUILD_ROOT/local-app/Superconnect FOSS Preview.app"
    SC_FOSS_LOCAL_RECEIPT="$SC_FOSS_BUILD_ROOT/local-app/mac-local-app-receipt-v1.json"

    DEVELOPER_DIR="$SC_FOSS_XCODE_DIR" \
    SC_MAC_CORE_FFI_LIBRARY_PATH="$SC_FOSS_CORE_DIR" \
    SC_FOSS_MAC_LOCAL_SIGN_IDENTITY="$SC_FOSS_LOCAL_SIGNER" \
    SC_FOSS_MAC_APP_PATH="$SC_FOSS_LOCAL_APP" \
    SC_FOSS_MAC_APP_RECEIPT_PATH="$SC_FOSS_LOCAL_RECEIPT" \
      "$SC_FOSS_ROOT/mac/assemble-foss-preview-local.sh"

This command alone creates local test evidence, not a release. Do not use ad-hoc or self-signed
signing as a fallback. Only the integration owner may package the exact accepted Apple Development
app under the v0.2.2 experimental exception. Screen Recording and Accessibility consent must be
granted normally; do not reset or migrate another app's permission.

## 7. Evidence required before the exact pair-run

Freeze and record:

- source commit and tree;
- Xcode, Swift, macOS SDK, and Rust identities;
- Core archive and Core receipt SHA-256;
- Mac executable SHA-256;
- test command, count, and result;
- local app bundle ID, signer, CDHash, and executable SHA-256 if an owner-only app is used;
- exact debug-signed prerelease APK/package/version/signing-certificate hashes;
- installed identities observed on both peers.

Then use the physical HarmonyOS tablet's 卓易通 Android environment. Record normal pairing,
changing pixels, fullscreen/exit, Stop, two reconnects, and sustained-session duration. That is
卓易通 Android compatibility evidence, not native HarmonyOS acceptance.

Until this freeze and pair-run occur, use NOT_EXECUTED for device behavior. Do not infer it from
source builds, local app launch, byte delivery, or an old v0.2.0 run.
