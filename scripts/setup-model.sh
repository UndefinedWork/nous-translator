#!/bin/zsh
set -euo pipefail
folder="$HOME/Library/Application Support/Nous Translator"
mkdir -p "$folder"
file="$folder/Index-Translate-2B.Q4_K_M.gguf"
expected_sha256="044b313d29342bd3b2c77cbb64023ca0d209bd9b3247763f9d162767ef2d746a"
url="${NOUS_MODEL_URL:-https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/resolve/main/Index-Translate-2B.Q4_K_M.gguf}"
if [[ -f "$file" ]]; then echo "Model already installed: $file"; exit 0; fi
curl --fail --location --retry 5 --connect-timeout 20 --continue-at - "$url" --output "$file.part"
python3 - "$file.part" "$expected_sha256" "${NOUS_SKIP_SHA256:-0}" <<'PY'
import hashlib, struct, sys
from pathlib import Path
p = Path(sys.argv[1])
expected = sys.argv[2].lower()
skip_sha = sys.argv[3] == '1'
with p.open('rb') as f:
    header = f.read(8)
    assert len(header) == 8 and header[:4] == b'GGUF', 'Invalid GGUF magic header'
    version = struct.unpack('<I', header[4:8])[0]
    assert version in (2, 3), f'Unsupported GGUF version: {version}'
    assert p.stat().st_size >= 1_000_000_000, 'Incomplete model file'
if not skip_sha:
    h = hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda: f.read(4 * 1024 * 1024), b''):
            h.update(chunk)
    actual = h.hexdigest()
    assert actual == expected, f'SHA-256 mismatch: expected {expected}, got {actual}'
PY
mv "$file.part" "$file"
echo "Model installed and verified: $file"
