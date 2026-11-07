#!/usr/bin/env python3
"""Acquire pinned build inputs. No account or remote API server is required."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
SOURCES = [
    ('quickjs-2026-06-04.tar.xz', 'b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a',
     'https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz'),
    ('curl-8.23.0.tar.xz', '8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5',
     'https://curl.se/download/curl-8.23.0.tar.xz'),
    ('mbedtls-3.6.7.tar.bz2', 'a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6',
     'https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.7/mbedtls-3.6.7.tar.bz2'),
    ('flac-1.5.0.tar.xz', 'f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920',
     'https://github.com/xiph/flac/releases/download/1.5.0/flac-1.5.0.tar.xz'),
]
SDK_PARTS = [
    '64067e5714044dfa043d809abc5c6fc010434f58bd4d40783b3320feeb157976',
    '8609b48f6d06627c51e447c28b210adc7b8b7b16a7c3a22556b4b2f1e6cb8727',
    '88a8ea2419e3d98e5674a97381154640b33afadeba164b59b21670b1e254f2eb',
    '452dfcd3ef882079c5e2c4420196b74dbe101a0198487c9cdf78e1a8e5995223',
    '6e4ae574565e664228329dd48d4da48100c69cecacfaa0e7e2e67a009c66864f',
]

def check(path, digest):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    if h.hexdigest() != digest:
        raise SystemExit(f'Checksum mismatch: {path}. Remove the file and retry.')

def download(path, url, digest):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        partial = path.with_suffix(path.suffix + '.part')
        subprocess.run(['/usr/bin/curl', '--fail', '--location', '--retry', '2', '--proto', '=https',
                        '--silent', '--show-error', url, '-o', str(partial)], check=True)
        check(partial, digest)
        partial.replace(path)
    check(path, digest)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--no-sdk', action='store_true', help='Use an existing SDK via IOS_SDK later')
    args = parser.parse_args()
    for name, digest, url in SOURCES:
        archive = ROOT / 'vendor/archives' / name
        download(archive, url, digest)
        target = ROOT / '.deps/src' / ('quickjs-2026-06-04' if name.startswith('quickjs-') else name.split('.tar.')[0])
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['/usr/bin/tar', '-xf', str(archive), '-C', str(target.parent)], check=True)
    ldid = ROOT / '.deps/bin/ldid'
    download(ldid, 'https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_macosx_x86_64',
             '9d46e0feedf96e399edfca09872802ba21e729f79c01927ad25ea2b0a35bca23')
    ldid.chmod(0o755)
    sdk = Path(os.environ.get('IOS_SDK', str(ROOT / '.deps/sdk71/iPhoneOS7.1.sdk')))
    if not args.no_sdk and not (sdk / 'usr/include/stdio.h').exists():
        print('Acquiring archived Apple iOS 7.1 SDK for local compilation; SDK is excluded from source delivery.')
        parts = []
        for i, digest in enumerate(SDK_PARTS, 1):
            name = f'iPhoneOS7.1.sdk.zip.{i:03d}'
            part = ROOT / '.deps/archives' / name
            url = 'https://raw.githubusercontent.com/qianjigui/iOS-sdks/189a487850e3351cf624b5cef9c8317138c89b05/iPhoneOS7.1.sdk/' + name
            download(part, url, digest)
            parts.append(part)
        archive = ROOT / '.deps/archives/iPhoneOS7.1.sdk.zip'
        with archive.open('wb') as output:
            for part in parts:
                with part.open('rb') as source:
                    shutil.copyfileobj(source, output, 1024 * 1024)
        (ROOT / '.deps/sdk71').mkdir(parents=True, exist_ok=True)
        subprocess.run(['/usr/bin/unzip', '-q', '-o', str(archive), '-d', str(ROOT / '.deps/sdk71')], check=True)
    subprocess.run(['python3', 'scripts/draw-assets.py'], check=True)
    print('Build inputs verified. Run bash scripts/build-deps.sh, then bash scripts/build.sh.')

if __name__ == '__main__':
    main()
