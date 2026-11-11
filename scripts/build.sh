#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
project_root="$PWD"
output="${NOUS_APP_OUTPUT:-$project_root/build/Nous Translator.app}"
runtime="${NOUS_RUNTIME_OUTPUT:-$project_root/build/runtime-macos14-arm64}"
identity="${NOUS_CODESIGN_IDENTITY:--}"
source_commit="$(git rev-parse HEAD 2>/dev/null || echo uncommitted)"
source_dirty="$(git status --porcelain 2>/dev/null || echo uncommitted)"

# Build from pinned source. Never distribute the host's Homebrew dylibs.
NOUS_RUNTIME_OUTPUT="$runtime" scripts/build-runtime.sh
stage="$(mktemp -d /tmp/nous-build.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
app="$stage/Nous Translator.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Runtime"
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/nous-swift-module-cache" \
    -target arm64-apple-macos14.0 -swift-version 5 -O -parse-as-library \
    Sources/*.swift -o "$app/Contents/MacOS/NousTranslator" -framework SwiftUI -framework AppKit
cp -R Resources/Licenses "$app/Contents/Resources/"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md PRIVACY.md SOURCE_NOTICE.md "$app/Contents/Resources/"
install -m 755 "$runtime/bin/llama-server" "$app/Contents/Resources/Runtime/llama-server"
cp "$runtime/runtime-version.env" "$app/Contents/Resources/Runtime/"
python3 - "$app" "$source_commit" "$source_dirty" <<'PY'
import json, plistlib, subprocess, sys
from pathlib import Path
version = json.loads(Path('version.json').read_text())
try:
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True, stderr=subprocess.DEVNULL).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip())
    dirty = dirty or bool(sys.argv[3]) or commit != sys.argv[2]
except subprocess.CalledProcessError:
    commit, dirty = 'uncommitted', True
info = dict(CFBundleExecutable='NousTranslator', CFBundleIdentifier='com.nous.translator',
    CFBundleName='Nous Translator', CFBundleDisplayName='Nous Translator',
    CFBundleIconFile='AppIcon.icns', CFBundleShortVersionString=version['version'],
    CFBundleVersion=str(version['build']), CFBundlePackageType='APPL',
    LSMinimumSystemVersion=version['minimum_macos'], LSUIElement=True,
    NSHighResolutionCapable=True, NousReleaseVersion=version['release'],
    NousReleaseChannel=version['channel'], NousSourceCommit=commit, NousSourceDirty=dirty)
(Path(sys.argv[1]) / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
xattr -cr "$app"
sign_args=(--force --sign "$identity")
if [[ "$identity" != - ]]; then sign_args+=(--options runtime --timestamp); fi
codesign "${sign_args[@]}" "$app/Contents/Resources/Runtime/llama-server"
codesign "${sign_args[@]}" "$app"
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
echo "Built: $output"
