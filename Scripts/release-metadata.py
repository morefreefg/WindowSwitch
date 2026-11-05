#!/usr/bin/env python3
"""Sign a release archive and write the public metadata used by the appcast."""
import hashlib,json,os,pathlib,plistlib,re,subprocess,sys,zipfile
root=pathlib.Path(__file__).resolve().parent.parent
archive=pathlib.Path(sys.argv[1]); tool=pathlib.Path(sys.argv[2]); key=pathlib.Path(sys.argv[3])
with zipfile.ZipFile(archive) as package:
    info=plistlib.loads(package.read('WindowSwitch.app/Contents/Info.plist'))
version=info['CFBundleShortVersionString']; tag=os.environ.get('GITHUB_REF_NAME','v'+version)
assert tag == 'v'+version and re.fullmatch(r'v\d+\.\d+\.\d+(?:-rc[.-]\d+)?',tag,re.I)
assert info['CFBundleIdentifier']=='io.github.morefreefg.WindowSwitch'
signature=subprocess.check_output([str(tool),'-f',str(key),'-p',str(archive)],text=True).strip()
subprocess.run(['xcrun','swift',str(root/'Scripts/verify-update.swift'),str(archive),signature,info['SUPublicEDKey']],check=True)
value={'version':version,'buildVersion':info['CFBundleVersion'],'minimumSystemVersion':info['LSMinimumSystemVersion'],
       'url':f'https://github.com/morefreefg/WindowSwitch/releases/download/{tag}/{archive.name}',
       'edSignature':signature,'length':archive.stat().st_size,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest()}
output=archive.with_suffix('.update.json');output.write_text(json.dumps(value,indent=2)+'\n')
files=sorted(p for p in archive.parent.iterdir() if p.is_file() and p.name!='SHA256SUMS')
(archive.parent/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
print('Wrote signed update metadata:',output.name)
