#!/usr/bin/env python3
"""Assemble a Mac App Store payload. Does not register, upload, or submit the app."""
import argparse
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
import importlib.util
spec = importlib.util.spec_from_file_location('release_verifier', ROOT / 'scripts/verify-release.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    version = json.loads((ROOT / 'version.json').read_text())
    destination = (args.output or ROOT / 'release' / (version['release'] + '-appstore')).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    if any(destination.iterdir()):
        raise SystemExit(f'Output must be empty: {destination}')
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('NousDistribution') != 'appstore':
        raise SystemExit('Pass an app built with NOUS_DISTRIBUTION=appstore')
    verifier.verify(app, build_only=True)
    staged = destination / 'Nous Translator.app'
    run('ditto', '--norsrc', app, staged)
    notes = destination / 'SUBMISSION-NOTES.txt'
    notes.write_text(
        'Mac App Store packaging notes\n'
        '=============================\n\n'
        'This script does not create an App Store Connect record, register a bundle ID,\n'
        'upload a package, or submit for review.\n\n'
        'Required before a real submission, none of which are stored in this repository:\n'
        '- A paid Apple Developer Program membership and a unique bundle ID on that team.\n'
        '- Apple Distribution signing identity and Mac App Store provisioning profile.\n'
        '- A public privacy-policy URL in App Store Connect (not defined here).\n'
        '- Export compliance answers. Info.plist does not set ITSAppUsesNonExemptEncryption.\n'
        '- Confirmation that inherited Pico application code may be distributed on the store.\n'
          '  SOURCE_NOTICE.md does not grant a uniform open-source license.\n'
        '- Sandbox, Services, local-model, and Metal validation on a Mac.\n'
        '- Run scripts/validate-appstore-macos.sh on an Apple Silicon Mac; it does not upload.\n\n'
        f'Built app copied to: {staged}\n'
        'Create an installer PKG only on a Mac after signing with Apple Distribution:\n'
        '  productbuild --component "Nous Translator.app" /Applications '
        '--sign "$NOUS_INSTALLER_IDENTITY" Nous-Translator-appstore.pkg\n',
        encoding='utf-8')
    identity = os.environ.get('NOUS_INSTALLER_IDENTITY', '').strip()
    if identity:
        pkg = destination / f'Nous-Translator-{version["release"]}-appstore.pkg'
        run('productbuild', '--component', staged, '/Applications', '--sign', identity, pkg)
        print(f'Created installer: {pkg}')
    else:
        print('No NOUS_INSTALLER_IDENTITY; copied the app and wrote SUBMISSION-NOTES.txt without a PKG.')
    print(f'App Store payload: {destination}')


if __name__ == '__main__':
    main()
