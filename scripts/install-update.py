#!/usr/bin/env python3
"""Replace the installed app, keeping a temporary backup until the update succeeds."""
import datetime
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import time

source = Path(sys.argv[1]).resolve()
candidates = [Path('/Applications/Nous Translator.app'), Path.home() / 'Applications/Nous Translator.app']
found = [path for path in candidates if path.exists() or path.is_symlink()]
if len(found) > 1:
    raise SystemExit('Multiple Nous Translator installations found; keep only one copy before updating: ' + ', '.join(str(p) for p in found))
if not found:
    raise SystemExit('No existing Nous Translator installation found in /Applications or ~/Applications.')
installed = found[0]
info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != 'com.nous.translator':
    raise SystemExit('Candidate bundle identifier does not match Nous Translator.')
if installed.is_symlink() or plistlib.loads((installed / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') != 'com.nous.translator':
    raise SystemExit('Existing installation is not the expected Nous Translator app.')
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
backup = Path.home() / 'Library/Application Support/Nous Translator/Backups' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S') / 'Previous.bundle-backup'
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
if reset.returncode:
    subprocess.run(['open', str(installed)], check=False)
    raise SystemExit('Update installed, but Accessibility reset failed; reset must be retried. Backup: ' + str(backup))
subprocess.run(['open', str(installed), '--args', '--request-accessibility-after-update'], check=True)
executable = str(installed / 'Contents/MacOS/NousTranslator')
for _ in range(40):
    if executable in subprocess.check_output(['ps', '-ax', '-o', 'comm='], text=True).splitlines():
        break
    time.sleep(0.25)
else:
    raise SystemExit('Could not confirm the new app started. Backup: ' + str(backup))
subprocess.run(['open', 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'], check=True)
shutil.rmtree(backup)
backup.parent.rmdir()
print('Installed and opened Nous Translator ' + info['NousReleaseVersion'] + '. Temporary backup removed; Accessibility reset for renewed user approval.')
