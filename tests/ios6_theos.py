#!/usr/bin/env python3
"""The alternate build must replace stale ARMv7 dependencies before linking."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='muyu-theos-ios6-') as directory:
    root = Path(directory)
    shutil.copyfile(ROOT / 'Makefile', root / 'Makefile')
    makefiles = root / 'theos/makefiles'
    makefiles.mkdir(parents=True)
    for name in ('common.mk', 'application.mk'):
        (makefiles / name).touch()
    tools = root / 'bin'
    tools.mkdir()
    fake = tools / 'bash'
    fake.write_text('''#!/bin/sh
printf '%s\\n' "$1" >> "$MC_BUILD_TRACE"
if [ "$1" = scripts/build-deps.sh ]; then
  mkdir -p .build/deps/lib
  touch .build/deps/lib/libcurl.a
  printf '%s\\n' armv7-apple-ios6.0 > .build/deps/.target
fi
''')
    fake.chmod(0o755)
    trace = root / 'trace'
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], MC_BUILD_TRACE=str(trace))
    def run():
        trace.write_text('')
        subprocess.run(['make', '--no-print-directory', '-s', 'before-all',
                        f'THEOS={root / "theos"}', f'THEOS_MAKE_PATH={makefiles}'],
                       cwd=root, env=env, check=True)
        return trace.read_text().splitlines()
    assert run() == ['scripts/build-deps.sh', 'scripts/build-quickjs.sh'], 'missing dependencies must build first'
    assert run() == ['scripts/build-quickjs.sh'], 'matching target cache should be reused'
    (root / '.build/deps/.target').write_text('armv7-apple-ios7.0\n')
    assert run() == ['scripts/build-deps.sh', 'scripts/build-quickjs.sh'], 'iOS 7 archives must be rebuilt'
print('Theos preflight: missing, matching, and stale target dependency checks passed')
