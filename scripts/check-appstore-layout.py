#!/usr/bin/env python3
"""Static checks for the Mac App Store edition that can run without macOS."""
import plistlib
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def fail(message):
    raise SystemExit(message)


def load_entitlements(path):
    return plistlib.loads(path.read_bytes())


def require(condition, message):
    if not condition:
        fail(message)


def main():
    app = load_entitlements(ROOT / 'Resources/Signing/NousTranslator.appstore.entitlements')
    helper = load_entitlements(ROOT / 'Resources/Signing/llama-server.appstore.entitlements')
    require(app.get('com.apple.security.app-sandbox') is True, 'App Store app entitlements must enable App Sandbox')
    for key in ('com.apple.security.network.client', 'com.apple.security.network.server',
                'com.apple.security.files.user-selected.read-only'):
        require(app.get(key) is True, f'Missing app entitlement {key}')
    require('com.apple.security.inherit' not in app, 'The app must not inherit another sandbox')
    require(set(helper) == {'com.apple.security.app-sandbox', 'com.apple.security.inherit'},
            'Helper entitlements must be exactly app-sandbox + inherit')
    require(helper.get('com.apple.security.app-sandbox') is True and helper.get('com.apple.security.inherit') is True,
            'Helper sandbox inherit flags must be true')

    build = (ROOT / 'scripts/build.sh').read_text()
    require('NOUS_DISTRIBUTION' in build and 'NOUS_APP_STORE' in build,
            'build.sh must support the App Store distribution and compiler flag')
    require('${NOUS_DISTRIBUTION:-direct}' in build, 'build.sh must default to the Direct edition')
    require('Contents/MacOS/llama-server' in build,
            'App Store builds must install the helper next to the application executable')
    require('Contents/Resources/Runtime/llama-server' in build,
            'Direct builds must keep the helper under Resources/Runtime')
    require('--identifier com.nous.translator.llama-server' in build,
            'App Store helper signing must set a stable code identifier')
    require('swift_args+=(-D NOUS_APP_STORE)' in build, 'App Store builds must define NOUS_APP_STORE')

    verify = (ROOT / 'scripts/verify-release.py').read_text()
    require("if distribution == 'appstore' and not build_only:" not in verify,
            'App Store entitlement checks must run for --build-only packages')
    require('Identifier=com.nous.translator.llama-server' in verify,
            'verify-release.py must require the helper signing identifier')
    require('com.apple.security.files.user-selected.read-only' in verify,
            'verify-release.py must require the user-selected file entitlement on the app')

    capture = (ROOT / 'Sources/SelectionCapture.swift').read_text()
    reader = (ROOT / 'Sources/SelectionAccessibilityReader.swift').read_text()
    keyboard = (ROOT / 'Sources/TelosKeyboardEvent.swift').read_text()
    for name, source in (('SelectionCapture', capture), ('SelectionAccessibilityReader', reader),
                         ('TelosKeyboardEvent', keyboard)):
        require('#if !NOUS_APP_STORE' in source and '#else' in source,
                f'{name} must compile a stub under NOUS_APP_STORE instead of an empty file')
    app_source = (ROOT / 'Sources/NousTranslatorApp.swift').read_text()
    require('Enable Selection Translation' in app_source,
            'Direct menu must still offer Enable Selection Translation')
    require('AXIsProcessTrusted' not in app_source.split('#if !NOUS_APP_STORE')[0],
            'App Store launch path must not call AXIsProcessTrusted outside a direct-only block')
    require('userData: String?' in app_source, 'Services selector must accept optional userData')
    require('NSScreen.main ?? NSScreen.screens.first' in app_source,
            'Clipboard/paste translation must not depend on NSScreen.main alone')
    require('#if NOUS_APP_STORE' in app_source and 'NSApp.servicesProvider' in app_source,
            'Only the App Store binary should register as a Services provider')

    providers = (ROOT / 'Sources/ModelProviders.swift').read_text()
    bytes_at = providers.find('session.bytes')
    require(bytes_at > 0, 'ModelProviders must own the remote HTTP stream')
    require('CloudAIConsent.ensureAllowed' in providers[:bytes_at],
            'remoteStream must require host consent before session.bytes')
    image = (ROOT / 'Sources/ImageRecognition.swift').read_text()
    require('CloudAIConsent.ensureAllowed' in image,
            'Online image recognition must require host consent even when tests inject a transport')
    require('ModelRouter.remoteStream' in image, 'Production image upload must use remoteStream')
    local = (ROOT / 'Sources/LocalModel.swift').read_text()
    require('127.0.0.1' in local, 'Local runtime traffic must stay on loopback')
    sources_root = ROOT / 'Sources'
    for path in sources_root.glob('*.swift'):
        text = path.read_text()
        if 'session.bytes' not in text:
            continue
        if path.name in {'LocalModel.swift', 'ModelProviders.swift'}:
            continue
        fail(f'{path.name} must not call session.bytes; outbound model HTTP belongs in ModelProviders')

    imported = (ROOT / 'Sources/ImportedModelStore.swift').read_text()
    require('.copying' in imported and 'disk space' in imported,
            'GGUF import must stage the copy and wrap disk failures')
    require('sanitizedFileName' in imported, 'Imported model names must be sanitized')

    notice = (ROOT / 'SOURCE_NOTICE.md').read_text()
    require('没有为整个 Nous Translator 应用另行指定 MIT' in notice,
            'SOURCE_NOTICE.md changed in an unexpected way')
    require('不另行授予' in notice, 'SOURCE_NOTICE.md must keep the unresolved-license statement')
    require('450fa2bc1dbf5651da513c2a2efd4c234f1dc7e2' in notice, 'SOURCE_NOTICE.md must keep the Pico baseline commit')

    privacy = (ROOT / 'PRIVACY.md').read_text()
    require('Mac App Store' in privacy, 'PRIVACY.md must describe the App Store text-entry paths')
    require('https://example.com/privacy' not in privacy, 'Do not invent a privacy-policy URL')
    require('Test Connection' in privacy and '按主机确认' in privacy,
            'PRIVACY.md must say Test Connection uses the same host confirmation')

    privacy_manifest = ROOT / 'Resources/PrivacyInfo.xcprivacy'
    manifest = plistlib.loads(privacy_manifest.read_bytes())
    require(manifest.get('NSPrivacyTracking') is False,
            'PrivacyInfo.xcprivacy must set NSPrivacyTracking to false until tracking exists')
    require('https://' not in privacy_manifest.read_text().lower(),
            'Do not invent URLs in PrivacyInfo.xcprivacy')

    import importlib.util
    spec = importlib.util.spec_from_file_location('write_info_plist', ROOT / 'scripts/write-info-plist.py')
    writer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(writer)
    with tempfile.TemporaryDirectory() as tmp:
        fake = Path(tmp) / 'Nous Translator.app'
        store_info = writer.write(fake, 'abc', '', 'appstore')
        direct_info = writer.info_dictionary(
            {'version': '0.6.0', 'build': 9, 'release': '0.6.0-beta.3', 'channel': 'preview',
             'minimum_macos': '14.0'}, 'abc', False, 'direct')
        require(store_info.get('NSServices', [{}])[0].get('NSMessage') == 'translateService',
                'Generated store Info.plist must declare translateService')
        require('NSPrincipalClass' not in store_info and 'NSPrincipalClass' not in direct_info,
                'SwiftUI @main Info.plist must omit NSPrincipalClass')
        require('NSServices' not in direct_info, 'Direct Info.plist must not register Services')
        require(direct_info['NousDistribution'] == 'direct', 'Direct template must stay direct')

    print('PASS: App Store entitlements, helper inherit/identifier, Direct defaults, '
          'consent choke points, license notice, privacy manifest, Info.plist')


if __name__ == '__main__':
    main()
