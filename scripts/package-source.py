#!/usr/bin/env python3
"""Package necessary project files; dependencies are fetched by bootstrap.py."""
from pathlib import Path
import subprocess
import zipfile, plistlib, re

root=Path(__file__).resolve().parent.parent
files=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root).decode().split('\0')
root_files={'.clang-format','.gitignore','LICENSE','Makefile','README.md','control'}
directories=('Sources/','Resources/','assets/','scripts/','tests/','vendor/licenses/')
documents={'docs/'+name for name in ('COMPATIBILITY.md','CUSTOM-SOURCES.md','DEPENDENCIES.md','INSTALL.md',
                                    'INTERFACES.md','LIBRARY.md','NETWORK.md','PLAYBACK.md')}
version=plistlib.loads((root/'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',version)
target=root/f'dist/MuyuMusic-source-{version}-ios6.zip'
target.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(target,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
    for name in sorted(set(filter(None,files))):
        if not (name in root_files or name.startswith(directories) or name in documents or
                (name.startswith('docs/releases/') and name.endswith('.md'))):
            continue
        path=root/name
        if path.is_file():
            archive.write(path,'MuyuMusic/'+name)
print(target)
