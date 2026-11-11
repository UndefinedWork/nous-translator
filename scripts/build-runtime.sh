#!/bin/bash
# Build the self-contained local inference helper. Requires macOS, Xcode command
# line tools, Git and CMake. No Homebrew runtime is copied into the application.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_root/scripts/runtime-version.env"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "The Nous Translator runtime must be built on macOS." >&2
    exit 1
fi
for tool in git cmake python3 xcrun; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done

source_root="$project_root/build/runtime-src/llama.cpp-$NOUS_LLAMA_COMMIT"
build_root="$project_root/build/runtime-build-macos14-$NOUS_RUNTIME_ARCH"
# Reuse the original cache when it belongs to this pin, but never feed a new
# source checkout into a CMake cache configured for a different commit.
if [[ -f "$build_root/CMakeCache.txt" ]] && ! grep -Fqx "CMAKE_HOME_DIRECTORY:INTERNAL=$source_root" "$build_root/CMakeCache.txt"; then
    build_root="$project_root/build/runtime-build-macos14-$NOUS_RUNTIME_ARCH-$NOUS_LLAMA_COMMIT"
fi
output_root="${NOUS_RUNTIME_OUTPUT:-$project_root/build/runtime-macos14-$NOUS_RUNTIME_ARCH}"
mkdir -p "$(dirname "$source_root")" "$output_root/bin"
if [[ ! -d "$source_root/.git" ]]; then
    git init -q "$source_root"
    git -C "$source_root" fetch --depth 1 "$NOUS_LLAMA_REPOSITORY" "$NOUS_LLAMA_COMMIT"
    git -C "$source_root" checkout -q --detach FETCH_HEAD
fi
if [[ "$(git -C "$source_root" rev-parse HEAD)" != "$NOUS_LLAMA_COMMIT" ]] ||
   [[ -n "$(git -C "$source_root" status --porcelain --untracked-files=normal)" ]]; then
    echo "Runtime source cache must be an unchanged checkout of $NOUS_LLAMA_COMMIT: $source_root" >&2
    exit 1
fi

# Use Apple's compiler and system SDK, not locally installed compiler libraries.
# Keep tools ON: upstream defines the server target inside the tools directory.
cmake -S "$source_root" -B "$build_root" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$(xcrun --find clang)" \
    -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$NOUS_RUNTIME_MACOS_MIN" \
    -DCMAKE_OSX_ARCHITECTURES="$NOUS_RUNTIME_ARCH" \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_USE_SYSTEM_GGML=OFF \
    -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_UI=OFF \
    -DLLAMA_USE_PREBUILT_UI=OFF \
    -DLLAMA_OPENSSL=OFF \
    -DLLAMA_BUILD_BORINGSSL=OFF \
    -DLLAMA_BUILD_LIBRESSL=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_CPU_KLEIDIAI=OFF \
    -DGGML_CCACHE=OFF \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=Apple \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build "$build_root" --config Release --target llama-server \
    --parallel "${NOUS_BUILD_JOBS:-$(sysctl -n hw.logicalcpu)}"

binary="$build_root/bin/llama-server"
# Refuse to package accidental host-specific builds or Homebrew dependencies.
python3 - "$binary" "$NOUS_RUNTIME_ARCH" "$NOUS_RUNTIME_MACOS_MIN" <<'PY'
import re
import subprocess
import sys

binary, architecture, minimum = sys.argv[1:]
def output(*args):
    return subprocess.check_output(args, text=True)

actual_arch = output("xcrun", "lipo", "-archs", binary).strip()
if actual_arch != architecture:
    raise SystemExit(f"Unexpected architecture: {actual_arch}; wanted {architecture}")
build = output("xcrun", "vtool", "-show-build", binary)
actual_minimum = re.search(r"\bminos\s+(\S+)", build)
if actual_minimum is None or actual_minimum.group(1) != minimum:
    raise SystemExit(f"Unexpected minimum macOS version:\n{build}")
dependencies = [line.strip().split(" (", 1)[0]
                for line in output("xcrun", "otool", "-L", binary).splitlines()[1:]]
external = [path for path in dependencies
            if not path.startswith(("/System/Library/", "/usr/lib/"))]
if external:
    raise SystemExit("Non-system runtime dependencies: " + ", ".join(external))
print(f"Verified runtime: {architecture}, macOS {minimum}+, system libraries only")
PY

install -m 755 "$binary" "$output_root/bin/llama-server"
cp "$project_root/scripts/runtime-version.env" "$output_root/runtime-version.env"
echo "Runtime ready: $output_root/bin/llama-server"
