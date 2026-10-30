#!/usr/bin/env python3
"""Keep arm64 in Sparkle's five binaries; leave all other resources intact."""
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]) / 'Contents/Frameworks/Sparkle.framework/Versions/B'
changed = False
for relative in ('Sparkle', 'Autoupdate', 'Updater.app/Contents/MacOS/Updater',
                 'XPCServices/Installer.xpc/Contents/MacOS/Installer',
                 'XPCServices/Downloader.xpc/Contents/MacOS/Downloader'):
    binary = root / relative
    architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    if 'arm64' not in architectures:
        raise SystemExit(f'Missing arm64: {relative}')
    if architectures != ['arm64']:
        subprocess.run(['lipo', str(binary), '-thin', 'arm64', '-output', str(binary)], check=True)
        changed = True
    assert subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip() == 'arm64'
if changed:
    print('changed')
