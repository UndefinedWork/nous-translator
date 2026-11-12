#!/usr/bin/env python3
"""Static checks for the Mac App Store edition that can run without macOS."""
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def fail(message):
    raise SystemExit(message)


def load_entitlements(path):
    return plistlib.loads(path.read_bytes())


def main():
    app = load_entitlements(ROOT / 'Resources/Signing/NousTranslator.appstore.entitlements')
    helper = load_entitlements(ROOT / 'Resources/Signing/llama-server.appstore.entitlements')
    if app.get('com.apple.security.app-sandbox') is not True:
        fail('App Store app entitlements must enable App Sandbox')
    for key in ('com.apple.security.network.client', 'com.apple.security.network.server',
                'com.apple.security.files.user-selected.read-only'):
        if app.get(key) is not True:
            fail(f'Missing app entitlement {key}')
    if 'com.apple.security.inherit' in app:
        fail('The app must not inherit another sandbox')
    if set(helper) != {'com.apple.security.app-sandbox', 'com.apple.security.inherit'}:
        fail('Helper entitlements must be exactly app-sandbox + inherit')
    if helper.get('com.apple.security.app-sandbox') is not True or helper.get('com.apple.security.inherit') is not True:
        fail('Helper sandbox inherit flags must be true')

    build = (ROOT / 'scripts/build.sh').read_text()
    if 'NOUS_DISTRIBUTION' not in build or 'NOUS_APP_STORE' not in build:
        fail('build.sh must support the App Store distribution and compiler flag')
    if 'Contents/MacOS/llama-server' not in build:
        fail('App Store builds must install the helper next to the application executable')

    capture = (ROOT / 'Sources/SelectionCapture.swift').read_text()
    reader = (ROOT / 'Sources/SelectionAccessibilityReader.swift').read_text()
    if '#if !NOUS_APP_STORE' not in capture or '#if !NOUS_APP_STORE' not in reader:
        fail('Accessibility selection sources must be excluded from App Store compilation')
    if 'AXIsProcessTrusted' in (ROOT / 'Sources/NousTranslatorApp.swift').read_text().split('#if !NOUS_APP_STORE')[0]:
        fail('App Store launch path must not call AXIsProcessTrusted outside a direct-only block')

    notice = (ROOT / 'SOURCE_NOTICE.md').read_text()
    if 'MIT' in notice and '没有为整个 Nous Translator 应用另行指定 MIT' not in notice:
        fail('SOURCE_NOTICE.md changed in an unexpected way')
    if '不另行授予' not in notice:
        fail('SOURCE_NOTICE.md must keep the unresolved-license statement')

    privacy = (ROOT / 'PRIVACY.md').read_text()
    if 'Mac App Store' not in privacy:
        fail('PRIVACY.md must describe the App Store text-entry paths')
    if 'https://example.com/privacy' in privacy:
        fail('Do not invent a privacy-policy URL')

    privacy_manifest = ROOT / 'Resources/PrivacyInfo.xcprivacy'
    manifest = plistlib.loads(privacy_manifest.read_bytes())
    if manifest.get('NSPrivacyTracking') is not False:
        fail('PrivacyInfo.xcprivacy must set NSPrivacyTracking to false until tracking exists')
    if 'https://' in privacy_manifest.read_text().lower():
        fail('Do not invent URLs in PrivacyInfo.xcprivacy')

    print('PASS: App Store entitlements, helper inherit, compiler flag, license notice, privacy manifest')


if __name__ == '__main__':
    main()
