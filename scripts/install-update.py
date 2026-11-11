#!/usr/bin/env python3
"""Install a verified candidate at the existing location, preserving data and a rollback copy."""
import datetime
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import time

source = Path(sys.argv[1]).resolve()
installed = Path.home() / 'Applications/Nous Translator.app'
info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != 'com.nous.translator':
    raise SystemExit('Candidate bundle identifier does not match Nous Translator.')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
staged = installed.parent / '.Nous Translator-update.app'
if staged.exists():
    raise SystemExit('An existing update staging directory needs inspection; nothing replaced.')
subprocess.run(['ditto', '--norsrc', str(source), str(staged)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
subprocess.run(['osascript', '-e', 'if application id "com.nous.translator" is running then tell application id "com.nous.translator" to quit'], check=True, timeout=15)
for _ in range(40):
    commands = subprocess.check_output(['ps', '-axo', 'command='], text=True).splitlines()
    if not any(line.startswith(str(installed / 'Contents/MacOS/NousTranslator')) or line.startswith(str(installed / 'Contents/Resources/Runtime/llama-server')) for line in commands):
        break
    time.sleep(0.25)
else:
    raise SystemExit('Application has not quit; installed version was not replaced.')
backup = Path.home() / 'Library/Application Support/Nous Translator/Backups' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S') / 'Nous Translator.app'
backup.parent.mkdir(parents=True)
installed.rename(backup)
try:
    staged.rename(installed)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(installed)], check=True)
except Exception:
    if installed.exists(): shutil.move(str(installed), str(backup.parent / 'failed-update.app'))
    backup.rename(installed)
    raise
# User preference: clear this app's stale Accessibility identity after every update.
# Never reset all services or other applications. macOS still requires the user to allow access.
reset = subprocess.run(['/usr/bin/tccutil', 'reset', 'Accessibility', 'com.nous.translator'])
subprocess.run(['open', str(installed)], check=True)
if reset.returncode:
    raise SystemExit('Update installed, but Accessibility reset failed. The app was reopened; reset must be retried.')
subprocess.run(['open', 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'], check=True)
print('Installed and opened Nous Translator ' + info['CFBundleShortVersionString'] + '. Previous version backed up; application data preserved; Accessibility reset for renewed user approval.')
