#!/usr/bin/env python3
"""Read-only guard: an update must satisfy the installed app's existing identity."""
import subprocess
import sys
from pathlib import Path
candidate = Path(sys.argv[1]).resolve()
installed = Path.home() / 'Applications/Nous Translator.app'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(candidate)], check=True)
result = subprocess.run(['codesign', '-d', '-r-', str(installed)], capture_output=True, text=True, check=True)
requirement = (result.stdout + result.stderr).split('designated =>', 1)[1].strip()
check = subprocess.run(['codesign', '--verify', '-R=' + requirement, str(candidate)], capture_output=True, text=True)
if check.returncode:
    raise SystemExit('Update blocked: the candidate does not satisfy the installed identity. Existing app and permissions were not changed.')
print('PASS: candidate satisfies the installed identity; no permissions were changed.')
