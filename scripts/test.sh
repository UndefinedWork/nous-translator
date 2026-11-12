#!/bin/bash
# Offline regression suite; never contacts paid model providers.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/write-info-plist.py --self-test
python3 scripts/check-appstore-layout.py
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcrun >/dev/null; then
    echo "Skipping Swift tests; they require macOS and Xcode command line tools."
    exit 0
fi
temp="$(mktemp -d /tmp/nous-tests.XXXXXX)"
trap 'rm -rf "$temp"' EXIT
flags=(-module-cache-path "${TMPDIR:-/tmp}/nous-swift-module-cache" -swift-version 5 -parse-as-library)
xcrun swiftc "${flags[@]}" Sources/TranslationLanguages.swift Sources/SelectionTranslationRules.swift tests/SelectionTranslationTests.swift -o "$temp/selection"
"$temp/selection"
xcrun swiftc "${flags[@]}" Sources/TranslationLanguages.swift Sources/SelectionTranslationRules.swift Sources/SelectionCapturePipeline.swift tests/SelectionCaptureTests.swift -o "$temp/capture"
"$temp/capture"
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/NousTranslatorApp.swift ]] || sources+=("$source")
done
for test in Composer Provider FirstLaunch ImageRecognition AttachmentFlow; do
    xcrun swiftc "${flags[@]}" "${sources[@]}" "tests/${test}Tests.swift" -o "$temp/$test" -framework AppKit -framework SwiftUI
    "$temp/$test"
done
xcrun swiftc "${flags[@]}" Sources/LocalModel.swift Sources/AppDistribution.swift tests/LocalModelTests.swift -o "$temp/LocalModel"
"$temp/LocalModel"
xcrun swiftc "${flags[@]}" Sources/LocalModel.swift Sources/ModelProviders.swift Sources/CloudAIConsent.swift Sources/AppDistribution.swift tests/StreamLifecycleTests.swift -o "$temp/StreamLifecycle" -framework AppKit
"$temp/StreamLifecycle"
xcrun swiftc "${flags[@]}" Sources/CloudAIConsent.swift Sources/LocalModel.swift Sources/ModelProviders.swift Sources/AppDistribution.swift tests/CloudAIConsentTests.swift -o "$temp/CloudAIConsent" -framework AppKit
"$temp/CloudAIConsent"
xcrun swiftc "${flags[@]}" Sources/ImportedModelStore.swift Sources/LocalModel.swift Sources/AppDistribution.swift tests/ImportedModelTests.swift -o "$temp/ImportedModel"
"$temp/ImportedModel"
xcrun swiftc "${flags[@]}" -D NOUS_APP_STORE Sources/ImportedModelStore.swift Sources/LocalModel.swift Sources/AppDistribution.swift tests/ImportedModelTests.swift -o "$temp/ImportedModelStore"
"$temp/ImportedModelStore"
store_sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/NousTranslatorApp.swift ]] || store_sources+=("$source")
done
xcrun swiftc "${flags[@]}" -D NOUS_APP_STORE "${store_sources[@]}" tests/ProviderTests.swift -o "$temp/ProviderStore" -framework AppKit -framework SwiftUI
"$temp/ProviderStore"
