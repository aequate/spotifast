# Verification record and remaining gates

Date: 22 October 2026. Development host: Windows x86_64. Rust 1.98.0 was
installed from the repository's pinned toolchain. There is no Apple SDK,
Xcode, iOS simulator, physical iPhone, signing identity, or Spotify test account
available in this environment.

## Checks executed here

| Check | Result and scope |
| --- | --- |
| Standalone iOS Rust core, `cargo check --locked --offline --manifest-path ios/Rust/Cargo.toml` | Passed on Windows; does not cross-compile for iOS |
| `cargo build --locked --offline --manifest-path ios/Rust/Cargo.toml` | Passed; produced the real Windows static library, not an iOS binary |
| `cargo test --locked --offline --manifest-path ios/Rust/Cargo.toml` | Passed after the audit and Jam-sharing additions: 42 tests, 0 failures; real DSP/buffer/ABI/state/link logic, no Spotify connection |
| `cargo clippy --locked --offline --manifest-path ios/Rust/Cargo.toml --all-targets -- -D warnings` | Passed; no Clippy/code warnings. Rust emitted environmental incremental-cache hard-link fallback warnings, not lint failures |
| iOS Rust formatting and root `cargo fmt --all --check` | Passed |
| Xcode OpenStep project parser | Parsed both targets, app/test phases, and every source reference |
| Deterministic project generator `--check` | Passed, 18 app Swift sources and three XCTest sources |
| Swift syntax parser | All 21 Swift files parsed without syntax errors; no SDK type checking |
| Native property lists and icon | Info/privacy property lists parse; icon is an opaque RGB 1024x1024 PNG |
| Shell script syntax | All three scripts pass `bash -n`; executed outside the Windows sandbox after its MSYS initialization was blocked |
| Dependency source policy | Passed against desktop and iOS manifests/lockfiles explicitly, including untracked iOS files |
| Upstream review-evidence and new-settings scripts | Passed for the existing tracked tree; no desktop settings fields or review captures were added |
| Credential-cache bug reproduction | Removing `with_memory_credentials` makes the focused handoff test fail with `None`; restoring it passes |
| Interrupted-output regression | New full-ring/no-render test failed before pause preemption and passed after it; no Spotify connection or native audio involved |
| Replacement-audio regression | New flush-then-publish test returned silence before repair and the exact replacement samples after epoch tagging; in-flight old-packet and FIFO stress tests also passed |
| Jam invite validation and C ABI | Seven new tests pass: exact query bytes, unresolved short links, deceptive origins, bounded payload, 256 appended-host bytes, printable encoded query domain, NUL/invalid UTF-8 |

The final suite passed 42 tests, including bounded output-stall handling,
decoder start/stop notifications and replacement audio preservation.
The 19 Swift XCTest methods (14 functional/model/security/QR tests and five native
layout/render tests) have not executed; source parsing is a separate, narrower
check. The epoch/interruption tests exercise decision helpers; they do not
prove a live OAuth or AVAudioSession lifecycle.

Syntax/tooling validation used Node 24.11.1, `xcode`'s OpenStep parser,
`web-tree-sitter` 0.20.8 and `tree-sitter-wasms`' Swift grammar. The grammar
required its matching runtime; the newer runtime could not load it. Node's
baseline WASM compiler was used (`--liftoff-only --no-wasm-tier-up`) after
optimized WASM compilation exceeded the sandbox's resources. The successful
final parsing run exited zero. These optional tools are not app dependencies.

To reproduce the optional project/Swift parser checks from a checkout:

```sh
npm install --prefix ios/build/qa --no-audit --no-fund xcode web-tree-sitter@0.20.8 tree-sitter-wasms
node --liftoff-only --no-wasm-tier-up ios/scripts/check-project.mjs --syntax
```

No Xcode build, XCTest execution, native Keychain round trip, Spotify sign-in,
audible output, Connect session, battery profile or rendered UI review passed
here. They remain unverified. No screenshot or fabricated device result is
included as evidence.

## Upstream checks that could not complete

The full desktop suite in CONTRIBUTING.md has not passed in this checkout.
An offline desktop Clippy attempt stopped while fetching the unchanged pinned
`crmne/cpal` source, which is absent from the host's dependency cache. The
desktop all-features checks also require MilkDrop's CMake/libclang/vcpkg setup,
and the docs build requires Ruby/Bundler/Jekyll; those tools were not configured.
The Linux packaging launcher suite was attempted but failed because sandboxed
temporary-directory writes and the Ruby dependency were unavailable. These
are not reported as passing tests. No desktop source, lockfile, or manifest
was modified to bypass them. The new iOS core avoids those desktop dependencies.

## macOS build gate

1. Run `bash ios/scripts/bootstrap-macos.sh` on a Mac with Xcode installed.
2. Run `bash ios/scripts/test-macos.sh` for format, lint, host Rust tests,
   property-list validation, the unsigned Debug simulator app build, and
   the unsigned Release arm64 phone build.
3. Set `SIMULATOR` to an installed iPhone simulator and rerun to execute the
   XCTest target. Resolve all Apple SDK type/link/compiler errors before
   treating the project as build-verified. The script saves a timestamped
   `.xcresult` in `ios/build/`. Open it in Xcode to inspect actual native
   render attachments; those attachments have not been produced here.
4. Build arm64 for a physical iPhone. Test a Release configuration as well as
   Debug; inspect static library slices and archive signing in Xcode.
5. Exercise the native Keychain test. It writes/updates/reads/deletes a unique
   temporary dummy item and never accesses a real stored Spotify grant.

The supplied GitHub Actions workflow is a future execution path, not evidence
that those steps have run.

## Real account and physical iPhone gate

Record the phone model, iOS version, Xcode version, Spotify app mode, Premium
eligibility and app build for each result. Keep credentials out of recordings.

- Authorize library access with the custom redirect. Cancel and deny consent;
  verify state mismatch and stale callbacks do not attach an account.
- Authorize streaming independently for the same account. Confirm the personal
  Client ID's token works with librespot's iOS client configuration. Attempt a
  different playback account and confirm the session is rejected.
- Quit/relaunch, reconnect with the reusable Keychain credential, revoke the
  grant, reconnect after network loss, and sign out while connecting. Confirm
  no prior account data reappears after a new sign-in.
- Play full tracks and episodes at each quality. Pause/resume, rapidly skip,
  seek around silent intros, repeat a track/context, toggle shuffle, change
  volume while paused, and verify gapless transitions. Check for stale sound,
  clipping, unexpected resume, underruns, or decoder stalls.
- Transfer both directions between the iPhone and a real Spotify desktop client.
  Verify track, position, queue and play/pause state, and that only the active
  local player offers queue rewriting controls. Try a restricted receiver and
  confirm it is disabled rather than apparently accepted.
- Queue B, C, B; use Play Next; remove only the second B; reorder manual items;
  start another album; clear manual items; skip to a queue row. Confirm duplicate
  occurrences and context order on both clients. Queue an album with repeated
  songs; fail a later fetch page and confirm no partial album is appended.
- Restore a saved session paused. Confirm account scope, context position and
  manual queue after a phone restart. Check a session whose track is no longer
  available and a context that changed on another client.
- Save/remove tracks, albums, shows and episodes; follow/unfollow an artist;
  create/edit playlists and append items. Refresh after changes in Spotify.
  Verify current Development Mode restrictions produce useful errors.
- Search rapidly, clear/replace a query during a slow response, paginate,
  paste Spotify track/album URLs, and test deleted/unavailable/local rows.
- Verify every EQ preset, boost/cut/preamp, balance and mono with actual audio.
  Confirm remote Connect audio is unaffected by local sound controls.
- Lock the phone for extended playback. Use Control Center, headset controls,
  AirPlay, Bluetooth and wired outputs. Interrupt with a call/Siri/alarm, unplug
  headphones, change routes during playback and exercise media-service reset.
  Confirm audio work stops when paused. Do not add silent audio to avoid iOS
  suspension. A paused background app is allowed to disappear from Connect.
- Open lyrics for a track with/without lyrics and an episode. Confirm no old
  song's text appears under the next one; test the empty/failure state.

## UI and performance gate

Test a small iPhone and a large one, portrait/landscape, light/dark/black themes,
largest Dynamic Type sizes, VoiceOver, Reduce Motion, loading/empty/error
states and the keyboard covering search. Verify labeled controls, focus order,
44-point touch areas, and readable contrast. Capture actual screenshots only
after rendering on Apple platforms, keeping review evidence out of the repo.

`LayoutTests` measures transport at 320/375/393/430/568 point widths with large,
xxxLarge and accessibility5 text in LTR/RTL, plus a long collection heading
and mini player at 320 points. It also attaches light/dark transport renders
and mini-player renders. A compact light/dark QR-card layout/render case and
native QR decode/pixel/border checks are also present; see [JAM.md](JAM.md).
Passing size assertions alone cannot prove that every
button is visible/hittable or that the tab bar, keyboard, safe areas and sheets
behave correctly. The full-screen checklist in [AUDIT.md](AUDIT.md) is required.

Use Instruments Allocations, Leaks, Time Profiler and Energy Log for idle,
foreground playback, 30 minutes of locked playback, pause, repeated searches,
library pagination and 50 transfers/skips. Record memory high-water marks,
steady-state CPU, wakeups, underruns, launch time and battery deltas. Confirm
stable memory over repeated use, no decoder/AVAudioEngine processing when
paused, no background Web API polling and no full-rate UI progress loop.
Configured cache/buffer budgets do not prove overall memory or battery goals.
