#!/usr/bin/env python3
"""Compress large ICNS representations with native macOS JPEG 2000 encoding."""
import pathlib
import struct
import sys
import tempfile
import subprocess

path = pathlib.Path(sys.argv[1])
original = path.read_bytes()
assert original[:4] == b"icns"
assert struct.unpack(">I", original[4:8])[0] == len(original)
chunks = []
cache = {}
offset = 8
with tempfile.TemporaryDirectory(prefix="magdot-icon-") as directory:
    png = pathlib.Path(directory) / "representation.png"
    jp2 = pathlib.Path(directory) / "representation.jp2"
    while offset < len(original):
        kind, size = struct.unpack(">4sI", original[offset:offset + 8])
        assert size >= 8 and offset + size <= len(original)
        data = original[offset + 8:offset + size]
        if kind in (b"ic07", b"ic08", b"ic09", b"ic10", b"ic13", b"ic14") and data.startswith(b"\x89PNG\r\n\x1a\n"):
            if data not in cache:
                png.write_bytes(data)
                subprocess.run(["/usr/bin/sips", "-s", "format", "jp2", "-s", "formatOptions", "45", str(png), "--out", str(jp2)], check=True, stdout=subprocess.DEVNULL)
                candidate = jp2.read_bytes()
                cache[data] = candidate if len(candidate) < len(data) else data
            data = cache[data]
        chunks.append(struct.pack(">4sI", kind, len(data) + 8) + data)
        offset += size
body = b"".join(chunks)
result = b"icns" + struct.pack(">I", len(body) + 8) + body
path.write_bytes(result)
print(f"Icon: {len(original):,} -> {len(result):,} bytes (JPEG 2000; all resolutions retained)")
