#!/bin/bash
# Offline regression suite; never contacts paid model providers.
# Pass --fast to skip real Apple Vision OCR checks during rapid iteration.
set -euo pipefail
cd "$(dirname "$0")/.."
fast=0
for arg in "$@"; do
    case "$arg" in
        --fast) fast=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

temp="$(mktemp -d /tmp/nous-tests.XXXXXX)"
trap 'rm -rf "$temp"' EXIT
flags=(-module-cache-path "${TMPDIR:-/tmp}/nous-swift-module-cache" -swift-version 5 -parse-as-library)
frameworks=(-framework AppKit -framework SwiftUI -framework Carbon -framework AVFoundation)
sources=()
for source in Sources/*.swift; do
    [[ "$source" == Sources/NousTranslatorApp.swift ]] || sources+=("$source")
done

# Compile shared app sources once as a testable library + module, in parallel with lightweight standalone tests.
pids=()
compile() {
    local name="$1"; shift
    (
        xcrun swiftc "${flags[@]}" "$@" 2>"$temp/$name.err"
    ) &
    pids+=("$!:$name")
}

compile NousCore -enable-testing -module-name NousCore -emit-library -emit-module -emit-module-path "$temp/NousCore.swiftmodule" "${sources[@]}" "${frameworks[@]}" -o "$temp/libNousCore.dylib"
compile selection Sources/TranslationLanguages.swift Sources/SelectionTranslationRules.swift tests/SelectionTranslationTests.swift -o "$temp/selection"
compile capture Sources/TranslationLanguages.swift Sources/SelectionTranslationRules.swift Sources/SelectionCapturePipeline.swift tests/SelectionCaptureTests.swift -o "$temp/capture"
compile LocalModel Sources/Localization.swift Sources/LocalModel.swift tests/LocalModelTests.swift -o "$temp/LocalModel"
compile StreamLifecycle Sources/Localization.swift Sources/LocalModel.swift Sources/ModelProviders.swift tests/StreamLifecycleTests.swift -o "$temp/StreamLifecycle"

wait_batch() {
    local failed=0
    for entry in "${pids[@]}"; do
        local pid="${entry%%:*}"
        local name="${entry#*:}"
        if ! wait "$pid"; then
            echo "FAILED to compile $name:" >&2
            cat "$temp/$name.err" >&2
            failed=1
        elif [[ -s "$temp/$name.err" ]]; then
            cat "$temp/$name.err" >&2
        fi
    done
    pids=()
    return "$failed"
}

wait_batch

# Link full-app test executables in parallel against the prebuilt NousCore module.
for test in Composer Provider FirstLaunch ImageRecognition AttachmentFlow Optimization Updater; do
    compile "$test" -I "$temp" -L "$temp" -lNousCore -Xlinker -rpath -Xlinker "$temp" "tests/${test}Tests.swift" "${frameworks[@]}" -o "$temp/$test"
done

wait_batch

"$temp/selection"
"$temp/capture"
"$temp/Composer"
"$temp/Provider"
"$temp/FirstLaunch"
if [[ "$fast" -eq 1 ]]; then
    "$temp/ImageRecognition" --skip-vision
    "$temp/AttachmentFlow" --skip-vision
else
    "$temp/ImageRecognition"
    "$temp/AttachmentFlow"
fi
"$temp/LocalModel"
"$temp/StreamLifecycle"
"$temp/Optimization"
"$temp/Updater"
