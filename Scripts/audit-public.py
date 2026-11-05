#!/usr/bin/env python3
"""Check distributable source and ZIP members without displaying private data."""
import argparse, pathlib, re, subprocess, sys, zipfile
parser=argparse.ArgumentParser()
parser.add_argument('--artifacts',type=pathlib.Path)
parser.add_argument('--history',action='store_true')
args=parser.parse_args()
root=pathlib.Path(__file__).resolve().parent.parent
issues=[]
home=re.compile(rb'/(?:Users|home)/([A-Za-z0-9_.-]{2,})/')
key=re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')
def check(name,data):
    if any(m.group(1) not in (b'runner',b'admin') for m in home.finditer(data)):
        issues.append(f'{name}: host-specific home path')
    if key.search(data): issues.append(f'{name}: private key material')
    if b'Apple ' + b'Development:' in data: issues.append(f'{name}: development signing identity')
    if pathlib.PurePosixPath(name).suffix.lower() in ('.p12','.p8','.keychain-db'):
        issues.append(f'{name}: credential file')
if args.artifacts:
    for archive in args.artifacts.glob('*.zip'):
        with zipfile.ZipFile(archive) as package:
            for member in package.infolist():
                if not member.is_dir(): check(member.filename,package.read(member))
    for path in args.artifacts.glob('*.build.json'): check(path.name,path.read_bytes())
else:
    names=subprocess.check_output(['git','ls-files','-c','-o','--exclude-standard'],cwd=root,text=True).splitlines()
    for name in sorted(set(names)):
        path=root/name
        if path.is_file(): check(name,path.read_bytes())
if args.history:
    records=subprocess.check_output(['git','log','--all','--format=%ae %ce'],cwd=root,text=True).splitlines()
    if any(line != 'morefreefg@gmail.com morefreefg@gmail.com' for line in records):
        issues.append('Git history: unapproved author or committer email')
if issues:
    print('\n'.join(issues),file=sys.stderr);sys.exit(1)
print('Public-content audit passed.')
