#!/bin/bash
# Self-contained Apple Silicon Mac validation for Nous Translator's two editions.
#
# This script is intended to be copied onto a Mac with Xcode command-line tools
# and run from a clone of UndefinedWork/nous-translator. It does not upload,
# notarize, register Bundle IDs, open App Store Connect, or invent licenses.
# It has not been executed in the Linux cloud-agent environment that authored it.
#
# Usage (from the repository root on macOS arm64):
#   ./scripts/validate-appstore-macos.sh
# Optional:
#   NOUS_CODESIGN_IDENTITY='Apple Distribution: …' ./scripts/validate-appstore-macos.sh
#   NOUS_INSTALLER_IDENTITY='3rd Party Mac Developer Installer: …' ./scripts/validate-appstore-macos.sh
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if [[ "$(uname -s)" != Darwin ]]; then
    fail "This checklist must run on macOS. Current kernel is $(uname -s)."
fi
arch="$(uname -m)"
if [[ "$arch" != arm64 ]]; then
    fail "This project ships arm64 only. Current architecture is $arch."
fi
command -v xcrun >/dev/null || fail "Install Xcode command-line tools (xcrun is missing)."
command -v python3 >/dev/null || fail "python3 is required."
command -v codesign >/dev/null || fail "codesign is required."
command -v git >/dev/null || fail "git is required."

log "=== 1. Offline tests (Direct + App Store compile flags) ==="
./scripts/test.sh

direct_app="${NOUS_DIRECT_OUTPUT:-/tmp/nous-direct-validate/Nous Translator.app}"
store_app="${NOUS_APPSTORE_OUTPUT:-/tmp/nous-appstore-validate/Nous Translator.app}"
rm -rf "$(dirname "$direct_app")" "$(dirname "$store_app")"
mkdir -p "$(dirname "$direct_app")" "$(dirname "$store_app")"

log "=== 2. Direct edition ad-hoc build (must keep AX + Resources/Runtime helper) ==="
NOUS_DISTRIBUTION=direct NOUS_APP_OUTPUT="$direct_app" ./scripts/build.sh
python3 scripts/verify-release.py --build-only "$direct_app"
direct_info="$(plutil -extract NousDistribution raw "$direct_app/Contents/Info.plist")"
[[ "$direct_info" == direct ]] || fail "Direct Info.plist NousDistribution is $direct_info"
[[ -x "$direct_app/Contents/Resources/Runtime/llama-server" ]] || fail "Direct helper missing under Resources/Runtime"
[[ ! -e "$direct_app/Contents/MacOS/llama-server" ]] || fail "Direct build must not place llama-server in MacOS"
if plutil -extract NSServices json "$direct_app/Contents/Info.plist" >/dev/null 2>&1; then
    fail "Direct Info.plist must not declare NSServices"
fi

log "=== 3. App Store edition layout build ==="
if [[ "${NOUS_CODESIGN_IDENTITY:--}" == - ]]; then
    log "No Apple Distribution identity in the environment; using ad-hoc store layout (NOUS_ALLOW_ADHOC_STORE=1)."
    log "Ad-hoc store binaries are for layout/sandbox checks only. Do not upload them."
    NOUS_DISTRIBUTION=appstore NOUS_ALLOW_ADHOC_STORE=1 NOUS_APP_OUTPUT="$store_app" ./scripts/build.sh
else
    NOUS_DISTRIBUTION=appstore NOUS_APP_OUTPUT="$store_app" ./scripts/build.sh
fi
python3 scripts/verify-release.py --build-only "$store_app"
store_info="$(plutil -extract NousDistribution raw "$store_app/Contents/Info.plist")"
[[ "$store_info" == appstore ]] || fail "Store Info.plist NousDistribution is $store_info"
[[ -x "$store_app/Contents/MacOS/llama-server" ]] || fail "Store helper missing under Contents/MacOS"
[[ ! -e "$store_app/Contents/Resources/Runtime/llama-server" ]] || fail "Store helper must not also live under Resources"
plutil -extract NSServices json "$store_app/Contents/Info.plist" >/dev/null \
    || fail "Store Info.plist missing NSServices"
[[ -f "$store_app/Contents/Resources/PrivacyInfo.xcprivacy" ]] || fail "PrivacyInfo.xcprivacy missing"

log "=== 4. Codesign / entitlement dump (local; not App Review) ==="
codesign --verify --deep --strict "$store_app"
codesign -d --entitlements :- "$store_app"
codesign -dv --verbose=4 "$store_app/Contents/MacOS/llama-server"
codesign -d --entitlements :- "$store_app/Contents/MacOS/llama-server"

log "=== 5. Package payload (no upload) ==="
payload="${NOUS_APPSTORE_PAYLOAD:-/tmp/nous-appstore-payload}"
rm -rf "$payload"
python3 scripts/package-appstore.py "$store_app" --output "$payload"

log ""
log "=== Built artifacts on this Mac ==="
log "Direct app:     $direct_app"
log "Store app:      $store_app"
log "Store payload:  $payload"
if [[ -n "${NOUS_INSTALLER_IDENTITY:-}" ]]; then
    log "Installer PKG was requested via NOUS_INSTALLER_IDENTITY. Confirm the PKG exists under $payload before handing it to Transporter on this Mac."
else
    log "No NOUS_INSTALLER_IDENTITY; payload is the signed .app plus SUBMISSION-NOTES.txt."
    log "Create a PKG only after signing with Apple Distribution:"
    log "  productbuild --component \"$store_app\" /Applications --sign \"\$NOUS_INSTALLER_IDENTITY\" \"$payload/Nous-Translator-appstore.pkg\""
fi

log ""
log "=== Manual checks this script cannot finish ==="
cat <<'EOF'
[ ] Direct: Enable Selection Translation still appears; granting Accessibility still reads a selection in TextEdit.
[ ] Direct: Translate Clipboard and Translate Pasted Text… still work.
[ ] Store: menu has no Enable Selection Translation; AXIsProcessTrusted is not invoked (log/sample).
[ ] Store: Translate Clipboard, paste window, and Services → Translate with Nous Translator.
[ ] Store: enable the service in System Settings → Keyboard → Keyboard Shortcuts → Services if hidden.
[ ] Store: choosing a GGUF copies it into the sandbox container Imported Models/ and llama-server can load it.
[ ] Store: filling the disk (or a read-only container) while importing a GGUF leaves no partial .copying file and shows the disk-space error.
[ ] Privacy: first OpenAI/DeepSeek/Custom/online-OCR/Test Connection prompt names the host; Cancel sends nothing; Revoke in Settings → Privacy.
[ ] Privacy: localhost Custom API does not prompt; Hugging Face model download is not that prompt.
[ ] Local model: Index-Translate loads on Metal/CPU in both editions (store helper inherits sandbox).
[ ] Do not upload, notarize-submit, or click Submit for Review from this script.
[ ] Pico license remains a missing declaration at commit 450fa2bc; do not invent a license in ASC.
[ ] Public privacy-policy URL and export-compliance answers are still not in the repository.
EOF

log ""
log "PASS: scripted Mac steps finished. Complete the manual list before any App Store Connect upload."
log "This run did not contact App Store Connect."
