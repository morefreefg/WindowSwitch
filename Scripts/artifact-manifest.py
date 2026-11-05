#!/usr/bin/env python3
"""Write public build metadata without host paths or signing subject names."""
import hashlib, json, pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
with (app/'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
binary = app/'Contents/MacOS/WindowSwitch'
signature = subprocess.run(['codesign','-dv',str(app)],capture_output=True,text=True,check=True).stderr
value = {'name':info['CFBundleName'], 'version':info['CFBundleShortVersionString'],
         'bundleID':info['CFBundleIdentifier'], 'minimumMacOS':info['LSMinimumSystemVersion'],
         'architectures':subprocess.check_output(['lipo','-archs',str(binary)],text=True).split(),
         'signature':'ad-hoc' if 'Signature=adhoc' in signature else 'certificate',
         'executableSHA256':hashlib.sha256(binary.read_bytes()).hexdigest()}
pathlib.Path(sys.argv[2]).write_text(json.dumps(value,indent=2)+'\n')
