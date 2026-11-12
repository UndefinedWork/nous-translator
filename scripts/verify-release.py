#!/usr/bin/env python3
"""Validate a release bundle without installing it or changing system settings."""
import argparse
import ctypes
import json
import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True, stderr=subprocess.STDOUT)


def verify(app, require_notarized=False, build_only=False):
    app = Path(app).resolve()
    version = json.loads((ROOT / 'version.json').read_text())
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    distribution = info.get('NousDistribution', 'direct')
    if distribution not in ('direct', 'appstore'):
        raise SystemExit(f'Unknown NousDistribution: {distribution!r}')
    expected = {'CFBundleIdentifier': 'com.nous.translator',
                'CFBundleShortVersionString': version['version'],
                'CFBundleVersion': str(version['build']),
                'LSMinimumSystemVersion': version['minimum_macos'],
                'NousReleaseVersion': version['release'],
                'NousReleaseChannel': version['channel'],
                'NousDistribution': distribution}
    for key, value in expected.items():
        if info.get(key) != value:
            raise SystemExit(f'{key}: expected {value!r}, found {info.get(key)!r}')
    helper = 'Contents/MacOS/llama-server' if distribution == 'appstore' else 'Contents/Resources/Runtime/llama-server'
    required = ['Contents/MacOS/NousTranslator', helper, 'Contents/Resources/Runtime/runtime-version.env',
                'Contents/Resources/AppIcon.icns', 'Contents/Resources/PRIVACY.md',
                'Contents/Resources/SOURCE_NOTICE.md', 'Contents/Resources/THIRD_PARTY_NOTICES.md',
                'Contents/Resources/PrivacyInfo.xcprivacy']
    if distribution == 'appstore':
        services = info.get('NSServices') or []
        if not services or services[0].get('NSMessage') != 'translateService':
            raise SystemExit('App Store builds must declare the Translate with Nous Translator service')
        if (app / 'Contents/Resources/Runtime/llama-server').exists():
            raise SystemExit('App Store builds must not also ship llama-server under Resources')
        if 'https://' in str(info.get('NSHumanReadableCopyright', '')).lower():
            raise SystemExit('Do not place an unverified URL in NSHumanReadableCopyright')
    for item in required:
        if not (app / item).is_file():
            raise SystemExit(f'Missing bundle resource: {item}')
    for license_file in (ROOT / 'Resources/Licenses').iterdir():
        bundled = app / 'Contents/Resources/Licenses' / license_file.name
        if license_file.is_file() and (not bundled.is_file() or bundled.read_bytes() != license_file.read_bytes()):
            raise SystemExit(f'Missing or changed bundled notice: {license_file.name}')
    runtime_pin = (ROOT / 'scripts/runtime-version.env').read_bytes()
    if (app / 'Contents/Resources/Runtime/runtime-version.env').read_bytes() != runtime_pin:
        raise SystemExit('Runtime source pin does not match this release')
    run('codesign', '--verify', '--deep', '--strict', app)
    executables = []
    for item in app.rglob('*'):
        if not item.is_file() or item.is_symlink():
            continue
        with item.open('rb') as file:
            magic = file.read(4)
        if magic not in [b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe']:
            continue
        executables.append(item)
        arch = run('xcrun', 'lipo', '-archs', item).strip()
        if arch != version['architecture']:
            raise SystemExit(f'Unexpected architecture {arch}: {item.name}')
        builds = run('xcrun', 'vtool', '-show-build', item)
        minimums = re.findall(r'\bminos\s+(\S+)', builds)
        parse = lambda value: tuple(int(n) for n in value.split('.')) + (0,) * (3 - len(value.split('.')))
        if not minimums or any(parse(v) > parse(version['minimum_macos']) for v in minimums):
            raise SystemExit(f'Unsupported minimum macOS version in {item.name}: {minimums}')
        dependencies = [line.strip().split(' (', 1)[0] for line in run('xcrun', 'otool', '-L', item).splitlines()[1:]]
        rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', run('xcrun', 'otool', '-l', item))
        for dependency in dependencies:
            if dependency.startswith(('/System/Library/', '/usr/lib/')):
                continue
            if dependency.startswith('@rpath/libswift') and '/usr/lib/swift' in rpaths:
                try:
                    # System libraries can reside only in dyld's shared cache.
                    ctypes.CDLL('/usr/lib/swift/' + dependency.split('/')[-1])
                    continue
                except OSError:
                    pass
            raise SystemExit(f'Unbundled/non-system dependency in {item.name}: {dependency}')
    if len(executables) != 2:
        raise SystemExit(f'Expected exactly the application and static runtime, found {len(executables)} Mach-O files')
    if distribution == 'appstore':
        helper_id = run('codesign', '-dv', '--verbose=4', app / 'Contents/MacOS/llama-server')
        if 'Identifier=com.nous.translator.llama-server' not in helper_id:
            raise SystemExit('App Store helper must be signed as com.nous.translator.llama-server')
        signature = run('codesign', '-d', '--entitlements', ':-', app)
        for key in ('com.apple.security.app-sandbox', 'com.apple.security.network.client',
                    'com.apple.security.network.server', 'com.apple.security.files.user-selected.read-only'):
            if key not in signature:
                raise SystemExit(f'App Store build is missing {key}')
        helper_sig = run('codesign', '-d', '--entitlements', ':-', app / 'Contents/MacOS/llama-server')
        if 'com.apple.security.app-sandbox' not in helper_sig or 'com.apple.security.inherit' not in helper_sig:
            raise SystemExit('App Store helper must inherit the app sandbox')
        if 'com.apple.security.files.user-selected' in helper_sig:
            raise SystemExit('Inherited helper must not declare its own file-access entitlements')
    elif distribution != 'appstore' and (require_notarized or version['channel'] == 'stable'):
        signature = run('codesign', '-dv', '--verbose=4', app)
        if 'Authority=Developer ID Application:' not in signature:
            raise SystemExit('Stable releases require a Developer ID Application signature')
        if require_notarized or not build_only:
            run('xcrun', 'stapler', 'validate', app)
            run('spctl', '--assess', '--type', 'execute', '--verbose=2', app)
    print(f"Verified {version['release']} ({distribution}): {len(executables)} arm64 executables, macOS {version['minimum_macos']} target, valid bundle signatures and notices")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--require-notarized', action='store_true')
    parser.add_argument('--build-only', action='store_true', help='Validate signatures before the separate notarization step')
    args = parser.parse_args()
    verify(args.app, args.require_notarized, args.build_only)
