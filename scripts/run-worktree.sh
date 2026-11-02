#!/bin/bash
# One canonical app per checkout. No UI-preview or alternate application bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?Set Developer ID signing identity}"
mkdir -p build
if [[ "${1:-}" != --build-only ]]; then
  python3 - <<'GUARD'
import json,pathlib
p=pathlib.Path.home()/'Library/Application Support/MagDot/gesture-status.json'
if p.exists() and json.loads(p.read_text()).get('calibrating'):
 raise SystemExit('Calibration is active. Finish or cancel it before rebuilding the running app.')
GUARD
  xcrun swift -e 'import AppKit; for app in NSRunningApplication.runningApplications(withBundleIdentifier:"com.maximkich.magdot") { _ = app.terminate() }'
  python3 - <<'WAIT'
import subprocess,time
for _ in range(120):
 rows=subprocess.check_output(['ps','-axo','comm='],text=True).splitlines()
 if not any(row.strip().endswith('/Contents/MacOS/MagDot') for row in rows):break
 time.sleep(.1)
else:raise SystemExit('MagDot did not exit; build was not started.')
WAIT
fi
build_number=$(python3 - <<'PY'
import json,pathlib,plistlib
p=pathlib.Path('build/worktree-build.json');n=int(pathlib.Path('BUILD_NUMBER').read_text())
if p.exists():n=max(n,int(json.loads(p.read_text())['build']))
for app in pathlib.Path('build').glob('MagDot*.app'):
 try:n=max(n,int(plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleVersion']))
 except (ValueError,FileNotFoundError,KeyError):pass
print(n+1)
PY
)
MAGDOT_BUILD_NUMBER="$build_number" MAGDOT_APP_PATH=build/MagDot.app bash scripts/build-app.sh
python3 - "$build_number" <<'PY'
import hashlib,json,pathlib,plistlib,sys,datetime
root=pathlib.Path.cwd();files=[]
for folder in ['app','src','scripts','config']:
 files += [p for p in (root/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts]
digest=hashlib.sha256()
for p in sorted(files):digest.update(str(p.relative_to(root)).encode());digest.update(p.read_bytes())
info=root/'build/MagDot.app/Contents/Info.plist';d=plistlib.loads(info.read_bytes());d.update(MagDotSourceWorktree=str(root),MagDotSourceDigest=digest.hexdigest());info.write_bytes(plistlib.dumps(d))
(root/'build/worktree-build.json').write_text(json.dumps({'build':sys.argv[1],'worktree':str(root),'app':str(root/'build/MagDot.app'),'sourceDigest':digest.hexdigest(),'builtAt':datetime.datetime.now(datetime.timezone.utc).isoformat()},indent=2))
PY
codesign --force --options runtime --sign "$SIGN_IDENTITY" build/MagDot.app
codesign --verify --deep --strict build/MagDot.app
if [[ "${1:-}" != --build-only ]]; then
  open -a "$PWD/build/MagDot.app" --args --experimental
fi
