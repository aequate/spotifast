# iOS dependency exception

The original desktop dependency pins and sources are unchanged. The separate
iOS manifest retains the exact librespot and hyper-proxy revisions used by the
desktop.

## sysinfo 0.36.1

The first real Apple builds failed on both simulator and device because
`sysinfo::ProcessInner::open_files` unconditionally referenced macOS-only libc
declarations. This is in a transitive dependency of librespot-core. Librespot
uses this crate's real `System::os_version` and `System::kernel_version`;
those methods must remain functional for Spotify client tokens. Enabling its
`unknown-ci` testing backend would replace those values and is not used.

There is no compatible 0.36.2 release or existing crmne/sysinfo fork. The user
explicitly approved a one-time iOS-only vendoring exception on 22 October 2026.
This approval applies to this independent port, not to an upstream pull request.
The original repository's policy script is unchanged.

`Vendor/sysinfo` comes from the official crates.io 0.36.1 archive, whose SHA256
matches the checksum originally in the port's lockfile:
`252800745060e7b9ffb7b2badbd8b31cfa4aa2e61af879d0a3bf2a317c20217d`.
Its MIT license and authorship are retained. Repository automation and ignore
files are omitted; the library, documentation, examples and tests are retained.

The only source change is [sysinfo-ios.patch](sysinfo-ios.patch): the existing
macOS method is compiled for macOS, and iOS returns `None` for the unsupported
process-file-count query. This query is not used by librespot. Real OS reporting
and every other library source file are unchanged. No playback, authentication
or networking implementation is substituted.

`scripts/check-dependencies.py` runs the original source policy with this one
explicit path exception, verifies every vendored file against its provenance
manifest, and verifies the exact changed method against the original hash.
Unexpected files, altered files or another local patch fail the check.

To reproduce the import, use `scripts/vendor-sysinfo.py` with the official
`sysinfo-0.36.1.crate` archive in a checkout without the Vendor/sysinfo directory,
then apply `git apply --directory=ios/Vendor/sysinfo ios/sysinfo-ios.patch`.
The script refuses archive mismatches and refuses to overwrite existing source.

Remove this exception when an approved librespot update uses an iOS-compatible
sysinfo release. Do not change the desktop lockfile to accomplish that.
