#!/usr/bin/env python3
"""Original dependency policy plus the explicitly approved, exact iOS exception."""
import hashlib
import importlib.util
import json
import os
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "ios" / "Vendor" / "sysinfo"
MANIFEST_SHA256 = "f902b778dd0a30c77da3dee1dbee8d41cd90240cfbb548728a1accd3e4e7448b"
CHANGED = "src/unix/apple/process.rs"
sys.dont_write_bytecode = True


def verify_vendor():
    manifest_bytes = (VENDOR / "SOURCE.json").read_bytes()
    if hashlib.sha256(manifest_bytes).hexdigest() != MANIFEST_SHA256:
        raise ValueError("Vendored source provenance manifest changed")
    manifest = json.loads(manifest_bytes)
    expected = manifest["files"]
    actual = {p.relative_to(VENDOR).as_posix() for p in VENDOR.rglob("*") if p.is_file()}
    if actual != set(expected) | {"SOURCE.json"}:
        raise ValueError("Unexpected or missing vendored files")
    for relative, digest in expected.items():
        path = VENDOR / relative
        if path.is_symlink():
            raise ValueError("Vendored source must not contain symlinks")
        data = path.read_bytes()
        if relative == CHANGED:
            text = data.decode()
            guard = '    #[cfg(target_os = "macos")]\n'
            ios = '    #[cfg(target_os = "ios")]\n    pub(crate) fn open_files(&self) -> Option<usize> {\n        None\n    }\n\n'
            if text.count(guard) != 1 or text.count(ios) != 1:
                raise ValueError("The iOS compatibility change is not the approved patch")
            data = text.replace(guard, "", 1).replace(ios, "", 1).encode()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("Vendored source changed beyond the approved patch: " + relative)


def main():
    verify_vendor()
    original = ROOT / ".github" / "scripts" / "check-dependency-sources.py"
    spec = importlib.util.spec_from_file_location("upstream_dependency_policy", original)
    policy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(policy)
    if (ROOT / ".git").exists():
        files = policy.tracked_manifests(ROOT)
    else:
        # Source bundles are buildable without a Git database too.
        files = {}
        for directory, folders, names in os.walk(ROOT):
            folders[:] = [name for name in folders if name not in (".git", "target", "build", ".build", "node_modules")]
            for name in names:
                path = Path(directory) / name
                relative = path.relative_to(ROOT).as_posix()
                if ("/" + relative).endswith(policy.MANIFESTS):
                    files[relative] = path.read_text(encoding="utf-8")
    manifest = tomllib.loads(files["ios/Rust/Cargo.toml"])
    if manifest["patch"]["crates-io"]["sysinfo"] != {"path": "../Vendor/sysinfo"}:
        raise ValueError("The approved local dependency must be exactly ../Vendor/sysinfo")
    exception = ("ios/Rust/Cargo.toml", "[patch] sysinfo must name a git repository under https://github.com/crmne/")
    failures = [problem for problem in policy.problems(files) if problem != exception]
    for path, message in failures:
        print(f"{path}: {message}", file=sys.stderr)
    if failures:
        return 1
    print("Dependency policy passed with the exact user-approved iOS sysinfo exception; vendored bytes verified.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError) as error:
        raise SystemExit(str(error))
