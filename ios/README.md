# Spotifast for iPhone

A separate native iOS port of [crmne/spotifast](https://github.com/crmne/spotifast),
based on upstream commit `8a4a6bcd2620cb2b033289acb44c4fbf0954a10d`.
Desktop application code and its Cargo manifest/lockfile are unchanged.

**Status: implemented source, host-tested Rust core, native integration awaiting
macOS and iPhone verification.** This is not a verified iOS release. No Spotify
account was used during development. Successful sign-in, streaming, transfers,
background playback, and iOS audio output have not been demonstrated here.
There is no fake catalogue, mock playback engine, or demo mode in this app.

The checked-in `Spotifast.xcodeproj` contains the iPhone app, shared scheme,
unit test target, native resources, configuration, and a Rust build phase.
Xcode builds the real librespot engine into the app; there is no prebuilt or
placeholder framework to replace later.

The pre-build audit and repairs are recorded in [AUDIT.md](AUDIT.md). Use the
latest source bundle when moving this project to your Mac. Native screen
rendering is still an open verification gate, rather than a claimed result.

## Build and install later

You need a Mac with Xcode 16 or newer and an iOS 17 or newer iPhone. Use the
latest Xcode supported by your phone's installed iOS version. Install Xcode's
command line tools and accept its license. Install Rust through
[rustup](https://rustup.rs). The repository pins Rust 1.98.0.

1. Copy this checkout to the Mac. Keep `ios/` beside the original `src/`
   directory: the Rust core imports three original modules by relative path.
2. From the checkout, run:

   ```sh
   bash ios/scripts/bootstrap-macos.sh
   ```

   This checks Xcode, installs the three iOS Rust targets, and fetches locked
   dependencies. The first build needs internet access and can take several minutes.
   Allow several gigabytes for Rust/Xcode build intermediates. The final iPhone
   app's installed size has not been measured; use Release for performance testing.
3. Open `ios/Spotifast.xcodeproj` in Xcode. Select the **Spotifast** scheme.
4. In the app target's **Signing & Capabilities**, choose your Apple team and
   a unique bundle identifier. Alternatively, copy
   `ios/Config/Local.xcconfig.example` to `ios/Config/Local.xcconfig` and fill
   in your team and identifier. This local file is ignored by Git.
5. Connect the iPhone, enable Developer Mode if requested, select it as the
   run destination, and build/run. Follow Xcode's device trust and provisioning
   instructions. Personal Team provisioning has Apple's expiration and capability
   limits; refresh the installation as your provisioning requires.

For a simulator build without signing:

```sh
xcodebuild -project ios/Spotifast.xcodeproj -scheme Spotifast \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

For a signed archive, select a generic iOS device in Xcode and choose
Product > Archive, then export using your account's available distribution
method. A sideloadable IPA must be built and signed on the Mac. No IPA or
signed binary is supplied or claimed verified from Windows.

The build phase supports arm64 iPhones, arm64 simulators, and x86_64
simulators. It selects the Rust target from Xcode's platform and architectures,
builds with `--locked`, and links the resulting static library. No XcodeGen,
CocoaPods, Swift package, Node runtime, embedded web view, or backend service
is required to build or run the app.

## Spotify setup

Create a personal app in the [Spotify developer dashboard](https://developer.spotify.com/dashboard).
Register this redirect URI **exactly**:

```text
spotifast-ios://oauth/callback
```

Enter its public Client ID on the app's sign-in screen, or set
`SPOTIFY_CLIENT_ID` in `Local.xcconfig`. Never add a client secret. Add your
Spotify account to the app's allowed users where required.

The app asks for two independent Authorization Code + PKCE grants through
`ASWebAuthenticationSession`:

- **Library/control:** profile, saved items, following, playlists, search,
  recent/top tracks, device list, remote control, and queue access.
- **Playback:** `streaming user-read-private`. The streaming token is passed
  to librespot. Its reusable credential is then stored in Keychain. The Rust
  session's username must match the verified library account.

After library sign-in, open Settings, choose **Authorize playback with
Spotify**, and then choose this iPhone in the device picker. Later launches
can reconnect using the saved approval. Starting audio is always explicit;
the app does not autoplay on launch. A retained session can be restored paused
using **Restore last track and queue** in Settings.

Spotify Premium is required for streaming. Current Development Mode requires
the app owner to have Premium, omits `/me`'s `product` field, and limits some
endpoints and playlist access. Missing plan information is treated as unknown,
not as a Free account. Spotify decides whether playback is permitted.
The custom app's streaming token and iOS session combination still need live
account testing. If Spotify rejects it, the app reports the failure. It does
not substitute another audio source or silently use the desktop application's
registered identity.

This port intentionally uses your registered mobile redirect instead of
reusing the desktop apps' loopback redirect registrations. It does not inherit
the shared desktop Web API application's broader quota or playlist coverage.

## Implemented workflows and verification limits

“Implemented” below means the production code path exists. It does not mean
the Spotify operation or native iOS integration was run successfully.

| Area | Implementation | Verification still needed |
| --- | --- | --- |
| Local playback | Real pinned librespot, Spotify audio, 96/160/320 kbps, normalization, gapless, native PCM output | Apple SDK build, Premium sign-in, audible output, transitions and long playback |
| Spotify Connect | Advertises this iPhone through Spirc; receives transfers and control; native picker lists signed-in devices; remote Web API control and queue append | Two real Spotify clients, same-account transfer, inactive/active state changes |
| Transport | Play/pause, next/previous, seek, shuffle, all three repeat modes, local player volume | Spotify acknowledgements, latency, rapid command sequences |
| Library | Paginated playlists, liked songs, saved albums, followed artists, shows, episodes; save/remove/follow/unfollow using generic library endpoints | Live account and permission coverage |
| Playlists | Read permitted playlists, create private playlists, edit owned name/description/visibility, add tracks/episodes | Owned/collaborative playlists, rejection behavior, changes from another client |
| Search/browse | Six searchable content types, ten results per page, cancellable debounce, album tracks, artist releases, podcast episodes, recent/top tracks | Real responses, relinking, null and restricted items |
| Queue | Separate manual/context entries, duplicate occurrences, append, Play Next, manual reorder/removal/clear, local skip-to-row, preserve manual entries across context loads | Full Spirc integration, transfer/imported queues, fast successive commands and late state |
| Equalizer | Original ten-band DSP and all original presets, preamp, stereo balance, mono, original limiter | Listening tests and Instruments profiling on hardware |
| Themes/UI | System/light/dark/black, semantic native controls, Dynamic Type, labeled buttons, scrolling compact-player layout | Actual rendering, small/large phones, landscape, VoiceOver and accessibility sizes |
| iOS integration | Audio session, AirPlay/Bluetooth route picker, interruption/headphone handling, lock-screen commands and Now Playing metadata | Hardware routes, phone calls, Control Center and background/locked playback |
| Lyrics | Real Spotify lyrics read through the signed-in playback session; plain text view and provider attribution | Live availability and network failures; automatic synchronized highlighting is absent |
| Jam invitations | Paste an existing Spotify invite, share/copy its exact link, generate/show/share a native QR image; open Spotify for hosting | Native QR decode/scan and share-sheet tests; creating/hosting/joining Jams within this port is unavailable |
| Persistence | Keychain grants, atomic preferences and account-scoped last queue/context/position, explicit paused restore | XCTest Keychain round trip, phone restart/upgrade and account switching |

Queue mutation controls are offered only while this iPhone is the active
player. Remote queues are read-only except append, as the Web API provides no
clear/reorder/remove/Play Next operation. A remote queue does not pretend to
identify manual entries. Queue writes are sent once; an ambiguous network
failure is shown instead of risking a duplicate append.

The app is a streaming client. It does not keep itself running with silent
audio when paused. iOS may suspend a background, paused app, so it is not an
always-on Connect receiver. Open the app and reconnect if necessary.

## Features not ported

- Signing in new LAN receivers, Cast sender authentication, and restricted
  Sonos control. Restricted devices are labeled and disabled in the picker.
  AirPlay and Bluetooth use iOS's native audio routes.
- Desktop shared/personal API routing, private Home recommendations, playlist
  folders, friend activity, radio, pre-saves, hidden songs, play counts, and
  private metadata fallback for playlists rejected by a personal Web API app.
- Playlist item removal/reordering, duplicate-safe playlist edits, cover
  uploads, multi-selection, and automatic library sorting.
- Imported local audio files, Winamp skins, MilkDrop, spectrum/oscilloscope
  visualizers, desktop menus/tray/shortcuts/autostart, proxy settings, and
  desktop self-updates. Installation updates follow your signing method.
- Offline listening, lossless, video podcasts, audiobooks, Smart Shuffle,
  Spotify DJ, crossfade, and playback speed. See the original repository's
  [capability boundaries](../docs/_reference/what-spotify-allows.md).
- Creating/hosting/joining/managing Spotify Jams inside librespot. **Jam invites**
  in Listen and Now playing shares an invite obtained from Spotify and creates
  a local QR code. It cannot obtain or renew a real invitation itself. See
  [JAM.md](JAM.md) for the supported flow and remaining device tests.

The reused link parser resolves pasted Spotify item URLs/URIs in Search.
System-wide Spotify link opening and a share extension have not been wired
into navigation. Prerelease links are explicitly unsupported.

## Memory, CPU and battery design

- SwiftUI/UIKit supplies the interface. No egui, desktop fastframe crates,
  browser engine, telemetry, or animation/visualizer rendering loop is linked.
- Rust uses a two-worker Tokio runtime and librespot's decoder. Network,
  decoding, DSP, JSON and disk persistence stay off the main UI thread.
- The render callback reads fixed planar float buffers through the C ABI.
  It allocates nothing, takes no lock, and never waits for the decoder.
  The PCM handoff stores 16,384 interleaved float samples, about 186 ms of
  stereo at 44.1 kHz. Samples use 64 KiB, and per-frame epoch tags use another
  64 KiB on arm64: 128 KiB total fixed payload. Tags discard old audio across
  a seek/skip while retaining the first replacement samples. Session
  replacement serializes decoder producers. Empty reads produce silence.
  A two-second no-progress timeout releases a blocked decoder if output
  stalls; interruption pause also preempts the writer directly.
- EQ/limiting run on the decoder thread. Flat/off EQ skips unnecessary filters;
  coefficient rebuilds happen only on changes. The AVAudioEngine stops when
  paused. The last output clamp guards a volume jump over already queued audio.
- Artwork is downsampled off the main thread, uses a 12 MiB NSCache cost budget,
  bounds downloaded image bytes to 4 MiB, and clears on memory pressure. The
  cache budget is not a guarantee about total process/image memory.
- Search waits 350 ms and cancels obsolete work. Lists load pages only when
  requested. Playback state uses Rust change notifications; only the full player
  redraws progress once per second. Remote playback polling runs only while
  the app is visible, every 15 seconds, or 30 with local playback. Polls do not
  run in the background. Spotify's own session traffic continues as required.
- Reads respect `Retry-After`; only one bounded read retry is attempted. Writes
  are not retried after an ambiguous failure. A 401 may refresh the grant once.
  Sign-out invalidates in-flight operations and removes stored grants/state.

These are design properties and configured budgets, **not measurements of
iPhone RAM, CPU, battery drain, binary size, or startup time**. No numeric
performance claim is made for the app before Instruments testing.

## Tests

From the checkout on Windows or macOS:

```sh
cargo fmt --manifest-path ios/Rust/Cargo.toml -- --check
cargo clippy --locked --manifest-path ios/Rust/Cargo.toml --all-targets -- -D warnings
cargo test --locked --manifest-path ios/Rust/Cargo.toml
```

The Rust tests execute real DSP, buffering, event folding and ABI logic with
deterministic test inputs. They do not contact Spotify or prove audible iOS
playback. The Swift XCTest target contains response parsing, duplicate rows,
plan-field absence, OAuth callback/PKCE, pagination-origin, and real temporary
Keychain round-trip tests, request/account epochs, interruption decisions,
and native component layouts. Those tests require Xcode and have not run here.
Jam-specific native tests also decode the generated QR back to the exact invite
and check its border/pixels; they have not run here either.

On a Mac, run:

```sh
bash ios/scripts/bootstrap-macos.sh
SIMULATOR='an installed iPhone simulator name' bash ios/scripts/test-macos.sh
```

The macOS test script runs Rust checks, validates property lists, builds the
Debug simulator app and unsigned Release arm64 phone app, and runs XCTest
when `SIMULATOR` is set. It writes a timestamped `.xcresult` in `ios/build/`
with native transport/mini-player render attachments for visual review. The
layout cases include 320–568 point widths, large/accessibility text, and RTL;
they are component checks, not complete screen/interaction coverage. See installed
devices using `xcrun simctl list devices available`. The supplied GitHub Actions
workflow selects an available iPhone simulator, but has not been dispatched.

The project generator is optional maintenance tooling. After adding/removing
a Swift source, run `node ios/scripts/generate-project.mjs`. See
[TESTING.md](TESTING.md) for actual results and the remaining device checklist,
[AUDIT.md](AUDIT.md) for repaired issues, and [ARCHITECTURE.md](ARCHITECTURE.md)
for the platform boundary.

## Privacy and sources

OAuth refresh grants and the reusable streaming credential are stored only in
this app's Keychain service with `AfterFirstUnlockThisDeviceOnly`. Ordinary
JSON contains public preferences and account-scoped listening metadata, never
tokens or passwords. Librespot's credential cache is memory-only; its normal
credential/audio file locations are not enabled. No credential is logged.

Network destinations are Spotify's authorization, Web API, access-point,
Dealer, metadata and audio endpoints and HTTPS artwork URLs Spotify returns.
The system authentication browser handles password entry. There is no LRCLIB
fallback, update check, hosted service, or analytics request in the iOS app.
The privacy manifest declares elapsed-time use; verify its coverage against
the final Apple SDK and dependency build before any store distribution.

Official references checked while implementing this port:

- [Spotify PKCE flow](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)
- [Spotify redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri)
- [Spotify 2026 Development Mode migration](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)
- [AVAudioSourceNode](https://developer.apple.com/documentation/avfaudio/avaudiosourcenode)
- [SwiftUI scene lifecycle](https://developer.apple.com/documentation/swiftui/scenephase)

MIT-licensed under the original [LICENSE](../LICENSE). App artwork is reused
from the original repository. Rust dependencies retain their respective
licenses. This is an independent port, not an official Spotify application.
