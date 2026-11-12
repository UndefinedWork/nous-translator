#!/usr/bin/env python3
"""Write Nous Translator Info.plist for direct or App Store distribution."""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def git_state(source_commit, source_dirty):
    try:
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True, stderr=subprocess.DEVNULL).strip()
        dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip())
        dirty = dirty or bool(source_dirty) or commit != source_commit
        return commit, dirty
    except (subprocess.CalledProcessError, FileNotFoundError):
        return 'uncommitted', True


def info_dictionary(version, commit, dirty, distribution):
    if distribution not in ('direct', 'appstore'):
        raise SystemExit(f'Unknown distribution: {distribution}')
    info = {
        'CFBundleExecutable': 'NousTranslator',
        'CFBundleIdentifier': 'com.nous.translator',
        'CFBundleName': 'Nous Translator',
        'CFBundleDisplayName': 'Nous Translator',
        'CFBundleIconFile': 'AppIcon.icns',
        'CFBundleShortVersionString': version['version'],
        'CFBundleVersion': str(version['build']),
        'CFBundlePackageType': 'APPL',
        'LSMinimumSystemVersion': version['minimum_macos'],
        'LSUIElement': True,
        'NSHighResolutionCapable': True,
        'NousReleaseVersion': version['release'],
        'NousReleaseChannel': version['channel'],
        'NousDistribution': distribution,
        'NousSourceCommit': commit,
        'NousSourceDirty': dirty,
    }
    if distribution == 'appstore':
        info['LSApplicationCategoryType'] = 'public.app-category.productivity'
        info['NSHumanReadableCopyright'] = (
            'Bundled third-party notices are in Contents/Resources. '
            'Application code provenance is described in SOURCE_NOTICE.md. '
            'This string does not name a copyright holder because that holder is not recorded in the repository.'
        )
        info['NSServices'] = [{
            'NSMenuItem': {'default': 'Translate with Nous Translator'},
            'NSMessage': 'translateService',
            'NSPortName': 'Nous Translator',
            'NSSendTypes': ['public.utf8-plain-text', 'NSStringPboardType'],
            'NSTimeout': 30000,
        }]
    return info


def write(app, source_commit='uncommitted', source_dirty='', distribution='direct'):
    version = json.loads((ROOT / 'version.json').read_text())
    commit, dirty = git_state(source_commit, source_dirty)
    info = info_dictionary(version, commit, dirty, distribution)
    destination = Path(app) / 'Contents/Info.plist'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(plistlib.dumps(info))
    return info


def self_test():
    version = {'version': '0.6.0', 'build': 9, 'release': '0.6.0-beta.3', 'channel': 'preview',
               'minimum_macos': '14.0'}
    direct = info_dictionary(version, 'abc', False, 'direct')
    store = info_dictionary(version, 'abc', False, 'appstore')
    assert direct['CFBundleIdentifier'] == 'com.nous.translator'
    assert direct['NousDistribution'] == 'direct'
    assert 'NSServices' not in direct
    assert 'NSHumanReadableCopyright' not in direct
    assert 'ITSAppUsesNonExemptEncryption' not in direct
    assert 'ITSAppUsesNonExemptEncryption' not in store
    assert store['NousDistribution'] == 'appstore'
    assert store['NSServices'][0]['NSMessage'] == 'translateService'
    assert 'holder is not recorded in the repository' in store['NSHumanReadableCopyright'].lower()
    blob = plistlib.dumps(store)
    assert b'https://' not in blob
    print('PASS: Info.plist templates for direct and App Store distributions')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('app', type=Path, nargs='?')
    parser.add_argument('--commit', default='uncommitted')
    parser.add_argument('--dirty', default='')
    parser.add_argument('--distribution', choices=('direct', 'appstore'), default='direct')
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        if args.app is None:
            raise SystemExit('Pass an .app path or --self-test')
        write(args.app, args.commit, args.dirty, args.distribution)
