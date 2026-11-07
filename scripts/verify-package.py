#!/usr/bin/env python3
"""Inspect the actual ARMv7 Mach-O rather than relying on compiler flags."""
import pathlib, plistlib, struct, subprocess, sys
app=pathlib.Path(sys.argv[1])
p=plistlib.loads((app/'Info.plist').read_bytes())
assert p['MinimumOSVersion']=='7.0'
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
                assert blob[where+37]==1, 'iOS 7 requires a primary SHA-1 CodeDirectory'
                primary=True
        assert primary
    if cmd in (0xc,0x80000018,0x8000001f):
        nameoffset=struct.unpack_from('<I',data,offset+8)[0]
        imports.append(data[offset+nameoffset:offset+size].split(b'\0')[0].decode())
    offset+=size
assert minimum==0x70000, f'Unexpected deployment version {minimum!r}'
assert signed, 'Missing code signature'
assert all(x.startswith(('/usr/lib/','/System/Library/Frameworks/')) for x in imports), imports
assert not any('swift' in x.lower() for x in imports)
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
print('Package verified: ARMv7 / iOS 7.0 minimum / ad-hoc signature / system dylibs / background audio / file sharing / CA and licenses')
