#!/usr/bin/env python3
"""Inspect a Mac App Store provisioning profile without contacting Apple.

Does not decode CMS cryptographically. Looks for the bundle identifier and
rejects development profiles that enable get-task-allow.
"""
import argparse
import re
import sys
from pathlib import Path

BUNDLE_ID = b'com.nous.translator'
ASC_BUNDLE_ID = b'536KMKRF6V'


def fail(message):
    raise SystemExit(message)


def verify(path):
    path = Path(path)
    if not path.is_file():
        fail(f'Provisioning profile is not a file: {path}')
    data = path.read_bytes()
    if BUNDLE_ID not in data:
        fail('Provisioning profile does not mention com.nous.translator')
    if re.search(br'get-task-allow</key>\s*<true\s*/>', data):
        fail('This looks like a development profile (get-task-allow). App Store uploads need a Mac App Store distribution profile.')
    if b'com.apple.application-identifier' not in data and b'application-identifier' not in data:
        fail('Provisioning profile is missing an application-identifier')
    if ASC_BUNDLE_ID not in data:
        print('NOTE: profile does not contain ASC bundle id 536KMKRF6V. '
              'That id is the Connect resource id; a Team ID / App ID prefix may differ. '
              'Continue only if this profile is the Mac App Store profile for com.nous.translator.')
    else:
        print('Profile contains 536KMKRF6V as well as com.nous.translator.')
    print(f'PASS: provisioning profile {path.name} names com.nous.translator and is not a development profile')


def self_test():
    import tempfile
    xml = b'''<?xml version="1.0"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>536KMKRF6V.com.nous.translator</string>
<key>com.apple.application-identifier</key><string>536KMKRF6V.com.nous.translator</string>
</dict></plist>'''
    with tempfile.TemporaryDirectory() as tmp:
        good = Path(tmp) / 'good.provisionprofile'
        good.write_bytes(xml)
        verify(good)
        bad = Path(tmp) / 'dev.provisionprofile'
        bad.write_bytes(xml.replace(b'</dict>', b'<key>get-task-allow</key><true/></dict>'))
        try:
            verify(bad)
        except SystemExit:
            pass
        else:
            fail('Development profiles must be rejected')
        missing = Path(tmp) / 'other.provisionprofile'
        missing.write_bytes(b'<plist><dict><key>application-identifier</key><string>OTHER.app</string></dict></plist>')
        try:
            verify(missing)
        except SystemExit:
            pass
        else:
            fail('Foreign bundle ids must be rejected')
    print('PASS: provisioning profile checks reject development and foreign profiles')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('profile', type=Path, nargs='?')
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.profile is None:
        sys.exit('Pass a .provisionprofile path or --self-test')
    else:
        verify(args.profile)
