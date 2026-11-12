#!/usr/bin/env python3
"""Fetch remote license evidence. Does not contact people or invent a license.

Classifies Pico as a missing declaration in the cited snapshot, not as proof
that rights are absent. Network failure is a skip, not a rights finding.
"""
import json
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PICO_COMMIT = '450fa2bc1dbf5651da513c2a2efd4c234f1dc7e2'
LLAMA_COMMIT = 'cd959bae99ff4bed22bef2604f45241c09bbb8c8'
LICENSE_NAMES = {'license', 'license.md', 'license.txt', 'copying', 'copying.md', 'licence', 'licence.md'}
UA = 'nous-translator-license-evidence/0.6.0-beta.3'


def fetch(url, timeout=20):
    request = urllib.request.Request(url, headers={'User-Agent': UA, 'Accept': 'application/json'})
    context = ssl.create_default_context()
    with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
        return response.read()


def classify_pico(entries):
    names = [item.get('name', '') for item in entries if isinstance(item, dict)]
    license_files = [name for name in names if name.lower() in LICENSE_NAMES]
    return names, license_files


def main():
    notice = (ROOT / 'SOURCE_NOTICE.md').read_text()
    third = (ROOT / 'THIRD_PARTY_NOTICES.md').read_text()
    llama_local = (ROOT / 'Resources/Licenses/llama.cpp.txt').read_text()
    index_local = (ROOT / 'Resources/Licenses/Index-Translate.txt').read_text()
    if PICO_COMMIT not in notice:
        raise SystemExit('SOURCE_NOTICE.md does not cite the Pico baseline commit used for this check')
    if LLAMA_COMMIT not in third:
        raise SystemExit('THIRD_PARTY_NOTICES.md does not cite the llama.cpp pin used for this check')
    if 'MIT' not in llama_local.splitlines()[0] and 'Permission is hereby granted' not in llama_local:
        raise SystemExit('Bundled llama.cpp notice does not look like the upstream MIT text')
    if 'Apache License' not in index_local:
        raise SystemExit('Bundled Index-Translate notice is not an Apache License text')

    try:
        pico_listings = {
            '/': fetch(f'https://api.github.com/repos/cellier/Pico/contents/?ref={PICO_COMMIT}'),
            'Pico/': fetch(f'https://api.github.com/repos/cellier/Pico/contents/Pico?ref={PICO_COMMIT}'),
            'Sources/': fetch(f'https://api.github.com/repos/cellier/Pico/contents/Sources?ref={PICO_COMMIT}'),
        }
        llama_raw = fetch(f'https://raw.githubusercontent.com/ggml-org/llama.cpp/{LLAMA_COMMIT}/LICENSE')
        hf_raw = fetch('https://huggingface.co/api/models/IndexTeam/Index-Translate-2B-GGUF')
    except (urllib.error.URLError, TimeoutError, ssl.SSLError) as error:
        print(f'SKIP: remote license fetch failed ({error}). Local notices still match SOURCE_NOTICE.md / THIRD_PARTY_NOTICES.md.')
        print('This skip is missing evidence, not a finding that rights are absent.')
        return 0

    all_license_files = []
    for folder, raw in pico_listings.items():
        entries = json.loads(raw.decode())
        if not isinstance(entries, list):
            print(f'SKIP: GitHub contents response for Pico {folder} was not a directory listing.')
            return 0
        names, license_files = classify_pico(entries)
        print(f'Pico {PICO_COMMIT} {folder} names: {", ".join(names[:24])}{"…" if len(names) > 24 else ""}')
        all_license_files.extend(f'{folder}{name}' for name in license_files)
    if all_license_files:
        print(f'CONTRADICTION: Pico snapshot now lists {all_license_files}; SOURCE_NOTICE.md must be revisited.')
        return 1
    print('FINDING: Pico snapshot has no LICENSE/COPYING at repository root, Pico/, or Sources/. '
          'That is a missing declaration in this commit, not proof of no rights.')

    llama_text = llama_raw.decode()
    if 'MIT License' not in llama_text and 'Permission is hereby granted' not in llama_text:
        print('CONTRADICTION: upstream llama.cpp LICENSE at the pinned commit is not MIT-shaped.')
        return 1
    if llama_local.strip().splitlines()[0] != llama_text.strip().splitlines()[0]:
        # Compare first line only; bundled file may include a local header.
        if 'MIT' not in llama_text:
            print('CONTRADICTION: llama.cpp upstream LICENSE does not mention MIT.')
            return 1
    print(f'llama.cpp {LLAMA_COMMIT} LICENSE: MIT evidence matches the bundled notice class.')

    card = json.loads(hf_raw.decode())
    license_id = (card.get('cardData') or {}).get('license') or card.get('license')
    gated = card.get('gated')
    print(f'Index-Translate-2B-GGUF card license={license_id!r} gated={gated!r}')
    if str(license_id).lower() not in {'apache-2.0', 'apache2', 'apache-2'}:
        print(f'CONTRADICTION: Hugging Face card license is {license_id!r}, not Apache-2.0.')
        return 1
    print('Remote evidence: llama.cpp MIT present; Index-Translate Apache-2.0 present; '
          'Pico license file missing at cited commit (unresolved rights, not proven absence).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
