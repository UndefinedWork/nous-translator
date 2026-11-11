import subprocess, sys
from pathlib import Path
root=Path(sys.argv[1])
# Copy and rewrite every non-system dependency, including Homebrew's transitive libraries.
queue=list(root.iterdir()); seen=set()
while queue:
    binary=queue.pop()
    if binary.name in seen: continue
    seen.add(binary.name)
    deps=subprocess.check_output(['otool','-L',str(binary)],text=True).splitlines()[1:]
    for line in deps:
        dep=line.strip().split(' (')[0]
        if dep.startswith('@rpath/') and (root/Path(dep).name).exists():
            subprocess.run(['install_name_tool','-change',dep,'@loader_path/'+Path(dep).name,str(binary)],check=True)
        if dep.startswith(('/opt/homebrew/','/usr/local/')):
            dest=root/Path(dep).name
            if not dest.exists():
                import shutil
                shutil.copy2(dep,dest); dest.chmod(dest.stat().st_mode | 0o200); queue.append(dest)
            subprocess.run(['install_name_tool','-change',dep,'@loader_path/'+dest.name,str(binary)],check=True)
    if binary.suffix=='.dylib': subprocess.run(['install_name_tool','-id','@loader_path/'+binary.name,str(binary)],check=True)
for binary in root.iterdir(): subprocess.run(['codesign','--force','--sign','-',str(binary)],check=True)
