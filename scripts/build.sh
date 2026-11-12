#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_root="$PWD"
output="${NOUS_APP_OUTPUT:-$project_root/build/Nous Translator.app}"
runtime="${NOUS_RUNTIME_OUTPUT:-$project_root/build/runtime-macos14-arm64}"
identity="${NOUS_CODESIGN_IDENTITY:--}"
distribution="${NOUS_DISTRIBUTION:-direct}"
source_commit="$(git rev-parse HEAD 2>/dev/null || echo uncommitted)"
source_dirty="$(git status --porcelain 2>/dev/null || echo uncommitted)"

if [[ "$distribution" != direct && "$distribution" != appstore ]]; then
    echo "NOUS_DISTRIBUTION must be direct or appstore" >&2
    exit 1
fi
if [[ "$distribution" == appstore && "$identity" == - && "${NOUS_ALLOW_ADHOC_STORE:-}" != 1 ]]; then
    echo "App Store builds need NOUS_CODESIGN_IDENTITY, or NOUS_ALLOW_ADHOC_STORE=1 for local layout tests." >&2
    exit 1
fi

# Build from pinned source. Never distribute the host's Homebrew dylibs.
NOUS_RUNTIME_OUTPUT="$runtime" scripts/build-runtime.sh
stage="$(mktemp -d /tmp/nous-build.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
app="$stage/Nous Translator.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Runtime"

swift_args=(-module-cache-path "${TMPDIR:-/tmp}/nous-swift-module-cache"
    -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library)
if [[ "$distribution" == appstore ]]; then
    swift_args+=(-D NOUS_APP_STORE)
fi
sources=()
for source in Sources/*.swift; do
    sources+=("$source")
done
xcrun swiftc "${swift_args[@]}" "${sources[@]}" -o "$app/Contents/MacOS/NousTranslator" \
    -framework SwiftUI -framework AppKit
cp -R Resources/Licenses "$app/Contents/Resources/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md PRIVACY.md SOURCE_NOTICE.md Resources/PrivacyInfo.xcprivacy "$app/Contents/Resources/"
cp "$runtime/runtime-version.env" "$app/Contents/Resources/Runtime/"
if [[ "$distribution" == appstore ]]; then
    install -m 755 "$runtime/bin/llama-server" "$app/Contents/MacOS/llama-server"
else
    install -m 755 "$runtime/bin/llama-server" "$app/Contents/Resources/Runtime/llama-server"
fi
python3 scripts/write-info-plist.py "$app" --commit "$source_commit" --dirty "$source_dirty" \
    --distribution "$distribution"
xattr -cr "$app"

app_entitlements="$project_root/Resources/Signing/NousTranslator.appstore.entitlements"
helper_entitlements="$project_root/Resources/Signing/llama-server.appstore.entitlements"
sign_args=(--force --sign "$identity")
if [[ "$identity" != - ]]; then sign_args+=(--options runtime --timestamp); fi
if [[ "$distribution" == appstore ]]; then
    codesign "${sign_args[@]}" --entitlements "$helper_entitlements" "$app/Contents/MacOS/llama-server"
    codesign "${sign_args[@]}" --entitlements "$app_entitlements" "$app"
else
    codesign "${sign_args[@]}" "$app/Contents/Resources/Runtime/llama-server"
    codesign "${sign_args[@]}" "$app"
fi
python3 scripts/verify-release.py --build-only "$app"
if [[ -e "$output" ]]; then
    # Only replace a build product with the expected application identity.
    python3 - "$output" <<'PY'
import plistlib, shutil, sys
from pathlib import Path
path = Path(sys.argv[1])
if path.is_symlink() or path.suffix != '.app':
    raise SystemExit('Refusing to replace a non-application output path')
info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != 'com.nous.translator':
    raise SystemExit('Refusing to replace a different application')
shutil.rmtree(path)
PY
fi
mkdir -p "$(dirname "$output")"
ditto --norsrc "$app" "$output"
xattr -cr "$output"
python3 scripts/verify-release.py --build-only "$output"
echo "Built ($distribution): $output"
