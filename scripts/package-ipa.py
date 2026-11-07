#!/usr/bin/env python3
"""Atomically replace the build artifact, preserving executable permissions."""
from pathlib import Path
import zipfile, plistlib, re

root=Path(__file__).resolve().parent.parent
package=root/'.build/package'
version=plistlib.loads((package/'Payload/MuyuMusic.app/Info.plist').read_bytes())['CFBundleShortVersionString']
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',version)
target=root/f'dist/MuyuMusic-{version}-armv7.ipa'
target.parent.mkdir(exist_ok=True)
temporary=target.with_suffix('.ipa.new')
with zipfile.ZipFile(temporary,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
    for path in sorted((package/'Payload').rglob('*')):
        if path.is_file():
            archive.write(path,path.relative_to(package))
temporary.replace(target)
