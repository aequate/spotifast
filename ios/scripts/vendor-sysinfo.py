#!/usr/bin/env python3
"""Reproduce the approved sysinfo source import from its original .crate."""
import hashlib
import json
import sys
import tarfile
from pathlib import Path, PurePosixPath

PACKAGE_SHA256 = "252800745060e7b9ffb7b2badbd8b31cfa4aa2e61af879d0a3bf2a317c20217d"
ROOT = Path(__file__).resolve().parents[1]
destination = ROOT / "Vendor" / "sysinfo"
archive = Path(sys.argv[1])
if hashlib.sha256(archive.read_bytes()).hexdigest() != PACKAGE_SHA256:
    raise SystemExit("The archive does not match the crates.io/locked sysinfo 0.36.1 checksum")
if destination.exists():
    raise SystemExit("Refusing to overwrite existing vendored source")
files = {}
with tarfile.open(archive) as source:
    for member in source.getmembers():
        parts = PurePosixPath(member.name).parts
        if parts[0] != "sysinfo-0.36.1" or ".." in parts or member.issym() or member.islnk():
            raise SystemExit("Unexpected archive path")
        if not member.isfile() or len(parts) < 2:
            continue
        # Repository automation/ignore files are not part of the library build.
        if parts[1] in (".github", ".cirrus.yml", ".gitignore"):
            continue
        relative = "/".join(parts[1:])
        data = source.extractfile(member).read()
        target = destination.joinpath(*parts[1:])
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        files[relative] = hashlib.sha256(data).hexdigest()
manifest = json.dumps({"version": "0.36.1", "archive_sha256": PACKAGE_SHA256, "files": files}, indent=2, sort_keys=True) + "\n"
(destination / "SOURCE.json").write_text(manifest, encoding="utf-8", newline="\n")
print("Verified official sysinfo source imported; apply ios/sysinfo-ios.patch next.")
print("SOURCE.json SHA256: " + hashlib.sha256(manifest.encode()).hexdigest())
