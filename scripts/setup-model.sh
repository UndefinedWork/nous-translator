#!/bin/zsh
set -euo pipefail
folder="$HOME/Library/Application Support/Nous Translator"
mkdir -p "$folder"
file="$folder/Index-Translate-2B.Q4_K_M.gguf"
if [[ -f "$file" ]]; then echo "Model already installed: $file"; exit 0; fi
curl --fail --location --retry 5 --connect-timeout 20 --continue-at - 'https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/resolve/main/Index-Translate-2B.Q4_K_M.gguf' --output "$file.part"
python3 - "$file.part" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1])
with p.open('rb') as f:
    assert f.read(4)==b'GGUF' and p.stat().st_size>1_000_000_000, 'Invalid or incomplete model file'
PY
mv "$file.part" "$file"
echo "Model installed: $file"
