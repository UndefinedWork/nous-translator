#!/bin/bash
# Produce an App Store PKG on an Apple Silicon Mac. Never uploads or submits.
#
# Required on the Mac (not stored in this repository):
#   NOUS_CODESIGN_IDENTITY        Apple Distribution identity
#   NOUS_INSTALLER_IDENTITY       3rd Party Mac Developer Installer identity
#   NOUS_PROVISIONING_PROFILE     Mac App Store .provisionprofile for com.nous.translator
#
# Optional:
#   NOUS_APP_OUTPUT / NOUS_APPSTORE_PAYLOAD
#
# This script refuses NOUS_ASC_UPLOAD=1. After an App record exists, upload the
# PKG with Transporter on that same Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }

if [[ "$(uname -s)" != Darwin ]]; then
    fail "prepare-appstore-upload.sh must run on macOS. Linux cannot codesign or productbuild."
fi
[[ "$(uname -m)" == arm64 ]] || fail "This project ships arm64 only."
[[ "${NOUS_ASC_UPLOAD:-}" != 1 ]] || fail "This script will not upload. Unset NOUS_ASC_UPLOAD and use Transporter after an App record exists."

identity="${NOUS_CODESIGN_IDENTITY:-}"
installer="${NOUS_INSTALLER_IDENTITY:-}"
profile="${NOUS_PROVISIONING_PROFILE:-}"
[[ -n "$identity" && "$identity" != - ]] || fail "Set NOUS_CODESIGN_IDENTITY to an Apple Distribution identity from the keychain."
[[ "$identity" == *'Apple Distribution'* || "$identity" == *'3rd Party Mac Developer Application'* ]] \
    || fail "NOUS_CODESIGN_IDENTITY must be Apple Distribution (or 3rd Party Mac Developer Application), not ad-hoc or Developer ID."
[[ -n "$installer" ]] || fail "Set NOUS_INSTALLER_IDENTITY to a 3rd Party Mac Developer Installer identity."
[[ -n "$profile" && -f "$profile" ]] || fail "Set NOUS_PROVISIONING_PROFILE to the Mac App Store profile for com.nous.translator."

python3 scripts/check-asc-status.py
python3 scripts/check-provisioning-profile.py "$profile"
./scripts/test.sh

store_app="${NOUS_APP_OUTPUT:-/tmp/nous-appstore-upload/Nous Translator.app}"
payload="${NOUS_APPSTORE_PAYLOAD:-/tmp/nous-appstore-upload-payload}"
rm -rf "$(dirname "$store_app")" "$payload"
mkdir -p "$(dirname "$store_app")"

log "Building the App Store edition with the distribution identity and embedded profile."
NOUS_DISTRIBUTION=appstore \
NOUS_REQUIRE_STORE_PROFILE=1 \
NOUS_CODESIGN_IDENTITY="$identity" \
NOUS_PROVISIONING_PROFILE="$profile" \
NOUS_APP_OUTPUT="$store_app" \
  ./scripts/build.sh

NOUS_REQUIRE_STORE_PROFILE=1 python3 scripts/verify-release.py --build-only "$store_app"
[[ -f "$store_app/Contents/embedded.provisionprofile" ]] || fail "embedded.provisionprofile missing after build"

NOUS_INSTALLER_IDENTITY="$installer" python3 scripts/package-appstore.py "$store_app" --output "$payload"

version="$(python3 -c 'import json; print(json.load(open("version.json"))["release"])')"
pkg="$payload/Nous-Translator-${version}-appstore.pkg"
[[ -f "$pkg" ]] || fail "productbuild did not write $pkg"

cat > "$payload/TRANSPORTER-NEXT.txt" <<EOF
Upload-ready PKG (this script did not upload it)
================================================
PKG: $pkg
App: $store_app
Bundle ID: com.nous.translator
ASC bundle id: 536KMKRF6V
App record: still missing as of docs/app-store/ASC-STATUS.json — Transporter will reject the PKG until the account holder creates the Mac app record for this bundle.

On this Mac, after the App record exists, use Transporter or:
  xcrun altool --upload-app --type macos --file "$pkg" --apiKey <ASC_API_KEY> --apiIssuer <ASC_ISSUER>
Do not pass API keys into this repository. Do not use notarytool; that is for Developer ID, not the Mac App Store.
Do not click Submit for Review until Pico rights, privacy URL, and export compliance are actually resolved.
EOF

log ""
log "Prepared: $pkg"
log "Next steps are in $payload/TRANSPORTER-NEXT.txt"
log "This run did not contact App Store Connect."
