#!/usr/bin/env python3
"""Resize the supplied artwork without external image libraries."""
from pathlib import Path
import subprocess, sys
root = Path(__file__).resolve().parent.parent
source = Path(sys.argv[1]).resolve() if len(sys.argv)>1 else root/'assets/AppArtwork.png'
output = root/'.build/tools/render-assets'
output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['clang','-fobjc-arc','-Wall','-Wextra','-Werror','-framework','AppKit',str(root/'scripts/render-assets.m'),'-o',str(output)],check=True)
subprocess.run([str(output),str(source),str(root/'Resources')],check=True)
