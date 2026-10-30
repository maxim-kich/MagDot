#!/usr/bin/env python3
"""Embed only public updater configuration; private signing material stays in Keychain."""
import base64
import pathlib
import plistlib
import sys

plist_path, key_path = map(pathlib.Path, sys.argv[1:])
key = key_path.read_text().strip()
if len(base64.b64decode(key, validate=True)) != 32:
    raise SystemExit("Sparkle public key must be a base64-encoded 32-byte Ed25519 key")
with plist_path.open("rb") as stream:
    info = plistlib.load(stream)
info.update({
    "SUFeedURL": "https://github.com/maxim-kich/MagDot/releases/latest/download/appcast.xml",
    "SUPublicEDKey": key,
    "SUEnableAutomaticChecks": False,  # Existing checkForUpdates preference/scheduler owns checks.
    "SUAutomaticallyUpdate": False,
    "SUAllowsAutomaticUpdates": False,
    "SUEnableSystemProfiling": False,
    "SUVerifyUpdateBeforeExtraction": True,
    "SURequireSignedFeed": True,
    "SUSignedFeedFailureExpirationInterval": 0,  # Never fall back to unsigned metadata.
    "SUShowReleaseNotes": False,
    "SUEnableJavaScript": False,
})
with plist_path.open("wb") as stream:
    plistlib.dump(info, stream)
