#!/usr/bin/env python3
"""Publish already-built, verified assets for the current committed version."""
import argparse
import hashlib
import importlib.util
import json
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = 'UndefinedWork/nous-translator'
spec = importlib.util.spec_from_file_location('release_verifier', ROOT / 'scripts/verify-release.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def run(*args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)


def output(*args):
    return subprocess.check_output([str(a) for a in args], cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--notes', type=Path, required=True)
    parser.add_argument('--assets', type=Path)
    args = parser.parse_args()
    version = json.loads((ROOT / 'version.json').read_text())
    release = version['release']
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[a-z]+\.\d+)?', release):
        raise SystemExit('Invalid release version')
    if version['channel'] not in ('preview', 'stable'):
        raise SystemExit('Release channel must be preview or stable')
    tag = 'v' + release
    notes = args.notes.resolve()
    if not notes.is_file() or not notes.read_text().strip():
        raise SystemExit('Release notes are required')
    if output('git', 'status', '--porcelain'):
        raise SystemExit('Commit and review all source changes before publishing')
    commit = output('git', 'rev-parse', 'HEAD')
    remote = output('gh', 'api', f'repos/{REPO}/commits/main', '--jq', '.sha')
    if remote != commit:
        raise SystemExit('Push this exact source commit to main before publishing')
    assets = (args.assets or ROOT / 'release' / release).resolve()
    manifest = json.loads((assets / 'release.json').read_text())
    if manifest['source_commit'] != commit or manifest['release'] != release or manifest['channel'] != version['channel']:
        raise SystemExit('Release assets do not match this committed source version')
    if version['channel'] == 'stable' and not manifest.get('notarized'):
        raise SystemExit('Stable releases must be Developer ID signed and notarized')
    expected = {f'Nous-Translator-{release}-macOS-{version["architecture"]}.dmg',
                f'Nous-Translator-{release}-macOS-{version["architecture"]}.zip', 'release.json'}
    listed = set()
    digests = {}
    for line in (assets / 'SHA256SUMS.txt').read_text().splitlines():
        sha, filename = line.split('  ', 1)
        if filename not in expected or filename in listed:
            raise SystemExit(f'Unexpected or duplicate release asset: {filename}')
        listed.add(filename)
        actual = hashlib.sha256((assets / filename).read_bytes()).hexdigest()
        if sha != actual:
            raise SystemExit(f'Checksum mismatch: {filename}')
        digests[filename] = actual
    if listed != expected:
        raise SystemExit('Incomplete release assets')
    if manifest.get('assets') != {name: sha for name, sha in digests.items() if name != 'release.json'}:
        raise SystemExit('Manifest checksums do not match the installation packages')
    if any(manifest.get(key) != version[key] for key in ('architecture', 'minimum_macos')):
        raise SystemExit('Manifest platform does not match this version')
    # Validate the actual binary again; a manifest flag alone cannot establish notarization.
    with tempfile.TemporaryDirectory(prefix='nous-publish-', dir='/tmp') as temporary:
        archive = assets / f'Nous-Translator-{release}-macOS-{version["architecture"]}.zip'
        run('ditto', '-x', '-k', archive, temporary)
        app = Path(temporary) / 'Nous Translator.app'
        verifier.verify(app)
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if info.get('NousSourceCommit') != commit or info.get('NousSourceDirty', True):
            raise SystemExit('Packaged app was not built from this clean source commit')
    exists = subprocess.run(['gh', 'release', 'view', tag, '--repo', REPO], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if exists.returncode == 0:
        raise SystemExit(f'{tag} already exists. Existing public releases are never overwritten automatically.')
    local_tag = subprocess.run(['git', 'rev-parse', '--verify', f'refs/tags/{tag}'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if local_tag.returncode == 0:
        if output('git', 'rev-list', '-n', '1', tag) != commit:
            raise SystemExit('Existing tag points to a different commit')
    else:
        run('git', 'tag', '-a', tag, '-m', f'Nous Translator {release}')
    run('git', 'push', 'origin', f'refs/tags/{tag}')
    command = ['gh', 'release', 'create', tag, '--repo', REPO, '--verify-tag', '--draft',
               '--title', f'Nous Translator {release}', '--notes-file', notes]
    if version['channel'] == 'preview':
        command.append('--prerelease')
    command += [assets / name for name in sorted(expected | {'SHA256SUMS.txt'})]
    run(*command)
    # All assets must exist before making the release public.
    uploaded = json.loads(output('gh', 'release', 'view', tag, '--repo', REPO, '--json', 'assets'))['assets']
    if {asset['name'] for asset in uploaded} != expected | {'SHA256SUMS.txt'}:
        raise SystemExit('Upload incomplete; release remains a draft for inspection')
    run('gh', 'release', 'edit', tag, '--repo', REPO, '--draft=false')
    print(f'https://github.com/{REPO}/releases/tag/{tag}')


if __name__ == '__main__':
    main()
