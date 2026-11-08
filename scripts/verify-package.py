#!/usr/bin/env python3
"""Inspect the actual ARMv7 Mach-O rather than relying on compiler flags."""
import pathlib, plistlib, re, struct, subprocess, sys
app=pathlib.Path(sys.argv[1])
p=plistlib.loads((app/'Info.plist').read_bytes())
assert p['MinimumOSVersion']=='6.0'
assert p['UIBackgroundModes']==['audio'] and p['UIFileSharingEnabled']
binary=app/p['CFBundleExecutable']
data=binary.read_bytes()
assert b'recordPlaybackDiagnostic\0' not in data and b'diagnosticSnapshot\0' not in data
assert b'music.playback.diagnostics\0' not in data
magic,cpu,sub,filetype,ncmds,sizeofcmds,flags=struct.unpack_from('<7I',data)
assert magic==0xfeedface and cpu==12 and sub&0xff==9, 'Expected 32-bit ARMv7 Mach-O'
offset=28; minimum=None; signed=False; imports=[]
for _ in range(ncmds):
    cmd,size=struct.unpack_from('<II',data,offset)
    if cmd==0x25: minimum=struct.unpack_from('<I',data,offset+8)[0]
    if cmd==0x1d:
        signed=True
        location,length=struct.unpack_from('<II',data,offset+8)
        blob=data[location:location+length]
        _,_,count=struct.unpack_from('>III',blob)
        primary=False
        for j in range(count):
            slot,where=struct.unpack_from('>II',blob,12+j*8)
            if slot==0:
                assert blob[where+37]==1, 'iOS 6 requires a primary SHA-1 CodeDirectory'
                primary=True
        assert primary
    if cmd in (0xc,0x80000018,0x8000001f):
        nameoffset=struct.unpack_from('<I',data,offset+8)[0]
        imports.append(data[offset+nameoffset:offset+size].split(b'\0')[0].decode())
    offset+=size
assert minimum==0x60000, f'Unexpected deployment version {minimum!r}'
assert signed, 'Missing code signature'
assert all(x.startswith(('/usr/lib/','/System/Library/Frameworks/')) for x in imports), imports
assert not any('swift' in x.lower() for x in imports)
# clang's availability runtime must tolerate an old system with no new dyld API.
symbols=subprocess.check_output(['nm','-m',str(binary)],text=True)
assert 'weak external __availability_version_check (dynamically looked up)' in symbols
dyld_imports=subprocess.check_output(['dyld_info','-imports',str(binary)],text=True)
assert '__availability_version_check [weak-import]' in dyld_imports

assert (app/'Licenses'/'Nayuki-QR-Code-generator-MIT.txt').is_file()
# No build can silently reuse iOS 7 static dependencies from another branch.
for archive in [pathlib.Path('.build/quickjs/armv7/libquickjs.a'), *pathlib.Path('.build/deps/lib').glob('*.a')]:
    loads=subprocess.check_output(['otool','-l',str(archive)],text=True)
    targets=re.findall(r'cmd LC_VERSION_MIN_IPHONEOS\s+cmdsize \d+\s+version ([0-9.]+)',loads)
    assert targets and all(tuple(map(int,v.split('.'))) <= (6,0) for v in targets), (archive, set(targets))
assert (app/'cacert.pem').stat().st_size>100000
assert list((app/'Licenses').glob('*'))
if tuple(map(int,p['CFBundleShortVersionString'].split('.'))) >= (1,2,0):
    assert (app/'LXPrelude.js').is_file(), 'Missing LX runtime prelude'
    assert list((app/'Licenses').glob('*QuickJS*')) or list((app/'Licenses').glob('*quickjs*')), 'Missing QuickJS license'
    assert (app/'Licenses'/'LX-documentation-MIT.txt').is_file()

entitlements=subprocess.check_output(['.deps/bin/ldid','-e',str(binary)])
entitlements=plistlib.loads(entitlements)
assert entitlements['get-task-allow'] is False, 'Release must disable debugger attachment'
assert entitlements['application-identifier']==p['CFBundleIdentifier']
assert entitlements['keychain-access-groups']==[p['CFBundleIdentifier']]
assert (app/'_CodeSignature/CodeResources').is_file()
print('Package verified: ARMv7 / iOS 6.0 minimum / ad-hoc signature / system dylibs / background audio / file sharing / CA and licenses')
