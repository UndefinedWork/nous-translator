#!/usr/bin/env python3
"""Recorded App Store Connect facts. Does not call ASC or invent missing fields."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATUS = ROOT / 'docs/app-store/ASC-STATUS.json'


def fail(message):
    raise SystemExit(message)


def main():
    status = json.loads(STATUS.read_text())
    if status.get('bundleIdentifier') != 'com.nous.translator':
        fail('ASC-STATUS.json must keep CFBundleIdentifier com.nous.translator')
    if status.get('ascBundleId') != '536KMKRF6V':
        fail('ASC-STATUS.json must keep the confirmed Connect bundle id 536KMKRF6V')
    url = status.get('privacyPolicyUrl')
    if url:
        lowered = str(url).lower()
        if 'example.com' in lowered or '[' in str(url):
            fail('Do not invent a privacy-policy URL')
    if status.get('picoLicense') == 'granted':
        fail('Do not mark Pico rights as granted in-repo without updating SOURCE_NOTICE.md')
    if status.get('picoLicense') != 'missing-declaration':
        fail('picoLicense must stay missing-declaration until a written grant exists')
    if status.get('exportComplianceAnswered') is True:
        fail('Do not mark export compliance answered from this repository')
    app_record = status.get('appRecord')
    print('ASC bundle identifier: com.nous.translator')
    print('ASC bundle id resource: 536KMKRF6V (registered)')
    print(f'App record: {app_record or "none — parent/account holder still needs to create it"}')
    print(f'Privacy policy URL in repo: {url or "none (not invented)"}')
    print('Export compliance: unanswered; Info.plist does not set ITSAppUsesNonExemptEncryption')
    print('Pico license: missing declaration at commit 450fa2bc, not proof of no rights')
    print('PASS: recorded ASC facts match the confirmed bundle registration and do not invent missing grants')


if __name__ == '__main__':
    main()
