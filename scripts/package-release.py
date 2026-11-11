#!/usr/bin/env python3
"""Create and verify a drag-to-Applications DMG, app ZIP and checksums."""
import argparse
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release_verifier', ROOT / 'scripts/verify-release.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def output(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as file:
        for data in iter(lambda: file.read(1024 * 1024), b''):
            sha.update(data)
    return sha.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    version = json.loads((ROOT / 'version.json').read_text())
    release = version['release']
    destination = (args.output or ROOT / 'release' / release).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        raise SystemExit(f'Release output must be empty: {destination}')
    # A release points to a committed source snapshot, not a machine-specific build tree.
    commit = output('git', '-C', ROOT, 'rev-parse', 'HEAD')
    if output('git', '-C', ROOT, 'status', '--porcelain'):
        raise SystemExit('Commit source changes before packaging a release')
    name = f'Nous-Translator-{release}-macOS-{version["architecture"]}'
    with tempfile.TemporaryDirectory(prefix='nous-package-', dir='/tmp') as temporary:
        stage = Path(temporary) / 'volume'
        stage.mkdir()
        app = stage / 'Nous Translator.app'
        # Strip Finder/resource fork metadata from the copy before signature checks.
        run('ditto', '--norsrc', args.app.resolve(), app)
        run('xattr', '-cr', app)
        verifier.verify(app)
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info.get('NousSourceCommit') != commit or info.get('NousSourceDirty', True):
            raise SystemExit('Build the app from this exact clean source commit before packaging')
        (stage / 'Applications').symlink_to('/Applications')
        (stage / 'Install.txt').write_text(
            'Nous Translator ' + release + '\n\n'
            '1. Drag Nous Translator.app into Applications.\n'
            '2. Open it from Applications. The app appears in the menu bar.\n'
            '3. In Settings > Models, download the local translation model (about 1.3 GB),\n'
            '   or configure a model provider of your choice.\n'
            '4. Allow Nous Translator in System Settings > Privacy & Security > Accessibility\n'
            '   to enable selection translation. Clipboard translation also works without it.\n\n'
            + ('PREVIEW: This build is ad-hoc signed and has not been notarized by Apple.\n'
               'If macOS blocks the first launch, confirm this came from the official release,\n'
               'then use System Settings > Privacy & Security > Open Anyway for this app.\n'
               'Do not disable macOS security globally. Managed Macs may prohibit this.\n'
               'Apple instructions: https://support.apple.com/en-us/102445\n\n'
               if version['channel'] == 'preview' else '')
            + 'Apple Silicon only. Deployment target: macOS ' + version['minimum_macos'] + '+.\n'
            'Downloads and support: https://github.com/UndefinedWork/nous-translator/releases\n', encoding='utf-8')
        zip_path = destination / (name + '.zip')
        dmg_path = destination / (name + '.dmg')
        run('ditto', '-c', '-k', '--keepParent', '--norsrc', app, zip_path)
        run('hdiutil', 'create', '-volname', f'Nous Translator {release}', '-srcfolder', stage,
            '-format', 'UDZO', '-fs', 'HFS+', '-ov', dmg_path)
        # Test the actual ZIP and DMG rather than only the input application.
        extracted = Path(temporary) / 'extracted'
        run('ditto', '-x', '-k', zip_path, extracted)
        verifier.verify(extracted / 'Nous Translator.app')
        mounted = plistlib.loads(subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(dmg_path)]))
        volume = next(Path(item['mount-point']) for item in mounted['system-entities'] if 'mount-point' in item)
        try:
            verifier.verify(volume / 'Nous Translator.app')
            if not (volume / 'Applications').is_symlink() or os.readlink(volume / 'Applications') != '/Applications':
                raise SystemExit('DMG is missing its Applications shortcut')
        finally:
            run('hdiutil', 'detach', volume)
    manifest = {
        'release': release, 'channel': version['channel'], 'source_commit': commit,
        'architecture': version['architecture'], 'minimum_macos': version['minimum_macos'],
        'build_host_macos': output('sw_vers', '-productVersion'),
        'swift_version': output('xcrun', 'swiftc', '--version'),
        'runtime_source': (ROOT / 'scripts/runtime-version.env').read_text().strip(),
        'notarized': version['channel'] == 'stable',
        'assets': {path.name: digest(path) for path in (dmg_path, zip_path)}
    }
    manifest_path = destination / 'release.json'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    files = (dmg_path, zip_path, manifest_path)
    (destination / 'SHA256SUMS.txt').write_text(''.join(f'{digest(path)}  {path.name}\n' for path in files))
    print(f'Packaged and verified: {destination}')


if __name__ == '__main__':
    main()
