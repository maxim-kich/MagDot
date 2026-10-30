#!/usr/bin/env python3
"""Explicit stages: prepare (local), notarize (Apple upload), draft (GitHub upload)."""
import argparse, hashlib, json, os, pathlib, re, subprocess, tarfile, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def run(*args, **kw):
 return subprocess.run([str(a) for a in args],check=True,**kw)
def capture(*args):return run(*args,stdout=subprocess.PIPE,text=True).stdout.strip()
def save(path,data):path.write_text(json.dumps(data,indent=2)+'\n')
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def archive(app,path):run('ditto','-c','-k','--sequesterRsrc','--keepParent',app,path)
def verify(app,notarized=False):
 run('codesign','--verify','--deep','--strict',app)
 info=run('codesign','-dv','--verbose=4',app,stderr=subprocess.PIPE,text=True).stderr
 if 'Authority=Developer ID Application:' not in info or 'Timestamp=' not in info:raise SystemExit('Developer ID signature with secure timestamp required')
 run(app/'Contents/MacOS/MagDot','--self-test')
 if notarized:
  run('xcrun','stapler','validate',app)
  run('spctl','--assess','--type','execute','--verbose=4',app)
def prepare():
 version=(ROOT/'VERSION').read_text().strip()
 if not re.fullmatch(r'\d+\.\d+\.\d+',version):raise SystemExit('VERSION must be numeric x.y.z')
 identity=os.environ.get('SIGN_IDENTITY')
 if not identity:raise SystemExit('Set SIGN_IDENTITY to your Developer ID Application identity')
 (ROOT/'dist').mkdir(exist_ok=True)
 folder=pathlib.Path(tempfile.mkdtemp(prefix=f'v{version}-',dir=ROOT/'dist'))
 app=folder/'MagDot.app'
 env=dict(os.environ,MAGDOT_APP_PATH=str(app),MAGDOT_TIMESTAMP_FLAG='--timestamp')
 run(ROOT/'scripts/build-app.sh',env=env,cwd=ROOT)
 verify(app)
 source=folder/f'MagDot-v{version}-source.tar.gz'
 files=capture('git','ls-files','--cached','--others','--exclude-standard','-z').split('\0')
 with tarfile.open(source,'w:gz') as tar:
  for name in files:
   path=ROOT/name
   if name and path.is_file():tar.add(path,arcname=f'MagDot-{version}/{name}',recursive=False)
 archive(app,folder/'notarization-upload.zip')
 manifest={'app_cdhash':run('codesign','-dv','--verbose=4',app,stderr=subprocess.PIPE,text=True).stderr.split('CDHash=')[1].splitlines()[0],'version':version,'build':(ROOT/'BUILD_NUMBER').read_text().strip(),'commit':capture('git','rev-parse','HEAD'),'dirty':bool(capture('git','status','--porcelain')),'stage':'prepared','source':source.name,'source_sha256':digest(source),'upload_sha256':digest(folder/'notarization-upload.zip')}
 save(folder/'manifest.json',manifest)
 print(f'Prepared locally: {folder}\nNo Apple or GitHub upload performed.')
def notarize_file(folder,path,profile,label):
 record=folder/f'{label}-submission.json'
 if not record.exists():
  result=json.loads(capture('xcrun','notarytool','submit',path,'--keychain-profile',profile,'--no-progress','--output-format','json'))
  save(record,result)
 submission=json.loads(record.read_text())['id']
 # Resumes the existing submission; never uploads again when an ID exists.
 subprocess.run(['xcrun','notarytool','wait',submission,'--keychain-profile',profile,'--timeout','20m','--no-progress'],check=False)
 result=json.loads(capture('xcrun','notarytool','info',submission,'--keychain-profile',profile,'--output-format','json'))
 save(folder/f'{label}-result.json',result)
 if result['status']!='Accepted':raise SystemExit(f"Notarization {result['status']}; rerun the same command to resume ID {submission}")
 run('xcrun','notarytool','log',submission,'--keychain-profile',profile,folder/f'{label}-log.json')
 run('xcrun','stapler','staple',path);run('xcrun','stapler','validate',path)
def notarize(folder,profile):
 m=json.loads((folder/'manifest.json').read_text());app=folder/'MagDot.app'
 if digest(folder/m['source'])!=m['source_sha256']:raise SystemExit('Source snapshot changed')
 if digest(folder/'notarization-upload.zip')!=m['upload_sha256']:raise SystemExit('Submission archive changed')
 verify(app)
 cdhash=run('codesign','-dv','--verbose=4',app,stderr=subprocess.PIPE,text=True).stderr.split('CDHash=')[1].splitlines()[0]
 if cdhash!=m['app_cdhash']:raise SystemExit('App changed after preparation')
 # ZIP itself cannot be stapled; submit ZIP, then staple its app.
 record=folder/'app-submission.json'
 if not record.exists():save(record,json.loads(capture('xcrun','notarytool','submit',folder/'notarization-upload.zip','--keychain-profile',profile,'--no-progress','--output-format','json')))
 sid=json.loads(record.read_text())['id']
 subprocess.run(['xcrun','notarytool','wait',sid,'--keychain-profile',profile,'--timeout','20m','--no-progress'],check=False)
 result=json.loads(capture('xcrun','notarytool','info',sid,'--keychain-profile',profile,'--output-format','json'));save(folder/'app-result.json',result)
 if result['status']!='Accepted':raise SystemExit(f"Apple status {result['status']}; rerun to resume {sid}")
 run('xcrun','notarytool','log',sid,'--keychain-profile',profile,folder/'app-log.json')
 run('xcrun','stapler','staple',app);verify(app,True)
 name=f"MagDot-v{m['version']}-macOS-arm64"
 zipfile=folder/f'{name}.zip';archive(app,zipfile)
 dmg=folder/f'{name}.dmg'
 if not dmg.exists():
  run(ROOT/'scripts/build-dmg.sh',app,dmg)
 if not (folder/'dmg-submission.json').exists():
  identity=os.environ.get('SIGN_IDENTITY')
  if not identity:raise SystemExit('Set SIGN_IDENTITY for DMG signing')
  run('codesign','--force','--timestamp','--sign',identity,dmg)
 notarize_file(folder,dmg,profile,'dmg')
 run('spctl','--assess','--type','open','--context','context:primary-signature','--verbose=4',dmg)
 if not (folder/'appcast.xml').exists():run(ROOT/'scripts/generate-update-feed.sh',zipfile,folder/'appcast.xml')
 assets=[zipfile.name,dmg.name,m['source'],'appcast.xml']
 (folder/'SHA256SUMS.txt').write_text(''.join(f'{digest(folder/a)}  {a}\n' for a in assets))
 m.update(stage='notarized',assets=assets+['SHA256SUMS.txt']);save(folder/'manifest.json',m)
 print('Notarized artifacts ready. No GitHub upload performed.')
def draft(folder,execute):
 m=json.loads((folder/'manifest.json').read_text());tag='v'+m['version']
 if m['stage']!='notarized' or m['dirty']:raise SystemExit('Draft requires notarized artifacts from a clean committed tree; prepare again after committing locally')
 if capture('git','status','--porcelain'):raise SystemExit('Commit the reviewed working tree before creating a release draft')
 if capture('git','rev-parse','HEAD')!=m['commit']:raise SystemExit('HEAD differs from packaged source')
 run('shasum','-a','256','-c','SHA256SUMS.txt',cwd=folder)
 notes=ROOT/'docs'/f"release-notes-{m['version']}.md"
 command=['gh','release','create',tag,'--repo','maxim-kich/MagDot','--verify-tag','--draft','--title',f"MagDot {m['version']}",'--notes-file',str(notes)]+[str(folder/a) for a in m['assets']]
 if not execute:print('Dry run only:', ' '.join(command));return
 if '## Before publication' in notes.read_text():raise SystemExit('Finalize release notes before uploading a draft')
 remote=capture('git','ls-remote','origin',f'refs/tags/{tag}^{{}}',f'refs/tags/{tag}')
 if m['commit'] not in remote:raise SystemExit('Remote release tag must resolve to the packaged commit')
 run(*command)
if __name__=='__main__':
 os.chdir(ROOT)
 p=argparse.ArgumentParser(description=__doc__);sub=p.add_subparsers(dest='stage',required=True)
 sub.add_parser('prepare')
 n=sub.add_parser('notarize');n.add_argument('folder',type=pathlib.Path);n.add_argument('--profile',default='magdot-notary')
 d=sub.add_parser('draft');d.add_argument('folder',type=pathlib.Path);d.add_argument('--upload',action='store_true')
 a=p.parse_args()
 if a.stage=='prepare':prepare()
 elif a.stage=='notarize':notarize(a.folder.resolve(),a.profile)
 else:draft(a.folder.resolve(),a.upload)
