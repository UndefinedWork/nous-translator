#!/bin/bash
# Offline regression suite; never contacts paid model providers.
set -euo pipefail
cd "$(dirname "$0")/.."
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
xcrun swiftc "${flags[@]}" Sources/LocalModel.swift tests/LocalModelTests.swift -o "$temp/LocalModel"
"$temp/LocalModel"
xcrun swiftc "${flags[@]}" Sources/LocalModel.swift Sources/ModelProviders.swift tests/StreamLifecycleTests.swift -o "$temp/StreamLifecycle"
"$temp/StreamLifecycle"
