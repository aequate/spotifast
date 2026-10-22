# Native iOS boundary

The desktop tree is the upstream baseline. The new app is under `ios/` with its
own Cargo manifest/lockfile and Xcode project. It does not add an iOS target to
the desktop GUI crate or alter existing dependency patches.

```text
SwiftUI views
    AppStore (main actor, observable UI and serialized user actions)
        SpotifyAPI actor -> URLSession -> Spotify Web API
        OAuthClient actor -> Keychain / token refresh
        BrowserSignIn -> ASWebAuthenticationSession -> Spotify PKCE
        RustBridge serial queue -> C ABI -> Rust Engine
            Tokio (2 workers) -> session / Spirc -> Spotify Connect
            librespot decoder -> original eq -> original limiter -> PCM ring
        AVAudioSourceNode -> C render -> PCM ring -> AVAudioEngine -> iOS routes
        MediaControls -> MPNowPlayingInfoCenter / MPRemoteCommandCenter
        PreferencesFile actor -> atomic local metadata/settings
```

## Reuse

The iOS crate includes `src/eq.rs`, `src/limiter.rs`, and `src/link.rs` by path.
Their original unit tests run in the iOS crate. Preset data and frequencies
cross the ABI from those original constants, rather than maintaining Swift
copies. Every librespot crate and hyper-proxy patch uses the same existing
`crmne` revision as the desktop.

`src/player.rs` could not be linked directly without pulling in desktop audio,
visualizers, API models, native power integration and settings. The iOS engine
adapts its session/player/Spirc/event design, using a native PCM sink in place
of rodio/fastframe-audio. Device integration, UI, authentication redirect and
secure storage are platform-specific Swift code. They do not depend on the
Spotify app being installed for local decoding.

## ABI and ownership

`Bridge/SpotifastCore.h` is the contract. The Rust library owns its runtime,
state, shared EQ and fixed PCM storage. `RustBridge.shared` keeps one engine
alive for the process lifetime so the audio callback never sees a freed pointer.
Sign-out disconnects its session; it does not destroy the render handle.

All JSON command and snapshot work runs on a dedicated serial control queue.
Notifications have no credential payload; the host copies the latest snapshot,
coalescing pending notifications. Reusable credentials are requested separately
and sent directly to the Keychain actor. Each returned C string has one
`sf_string_free` call. Inputs are borrowed only for the duration of the call.
The ABI catches ordinary Rust unwinds and returns sanitized errors. Invalid
commands never echo the input into logs or UI messages.

The native audio block captures only the stable C handle. It hands two disjoint
float buffers to `sf_render`. Only that callback consumes the ring. Decoder
producers are serialized off the real-time thread; generation checks prevent
a replaced decoder writing or stopping the new session. Acquire/release indices
publish complete stereo frames. PCM slots are atomic, so flush/skip races do
not create a data race. Each stereo frame carries the decoder's captured epoch,
so a flush invalidates only old frames, including publication racing that
flush. Newly decoded replacement samples survive the next render callback.
The fixed payload is 128 KiB on arm64 (64 KiB samples plus 64 KiB epoch tags).
Flush resets DSP state on the next decoded block. Local pause invalidates the
queued tail and wakes a writer before the player handles pause; a two-second
no-progress timeout also bounds native-output failure. Pause/resume timing
and audible transitions still require hardware listening tests.

## State, queue and failures

Playback actions update visible state optimistically and then run through a
serialized command chain. Catalogue/library work does not block that chain.
Recent optimistic state is held over delayed reads, with a scheduled final
snapshot after the hold expires. Commands capture their target device, and
delayed failures cannot roll back a newer account's state. Sign-out cancels
all registered action tasks and invalidates account/auth/HTTP generations
before clearing credentials. The HTTP session is replaced instead of racing
a deferred enumeration of old tasks against new-account requests.
Native snapshots and account-scoped persistent state are checked against the
verified account; playback cannot attach a different username's session.

The queue snapshot comes from actual Spirc `SetQueue` events, with provider
markers distinguishing manual items from context. Swift rows carry occurrence
IDs so duplicate URIs remain separate rows. Rewrites validate all URIs first,
clear only manual entries, and re-add ordered manual occurrences through Spirc.
A collection load supplies the manual occurrences to preserve, because librespot
clears upcoming entries on load. All-or-nothing album fetching happens before
any queue command is sent. Server-side partial acceptance is never represented
as an atomic transaction; failures are shown and the queue can be reloaded.
Album fetches retain their account/device and queue-edit revision; clearing
the manual queue or signing out cancels their eventual append. Queue rewrites
are validated against actual local active-device state in Rust as well as UI.

Remote queues follow the Web API's narrower capabilities. The port cannot
rewrite a queue on another device. It does not infer a manual/context boundary
from the remote Web API response.

Only native runtime state is event-driven. Visible remote playback is polled,
because the Web API has no pushed state. Foreground reads have bounded request
timeouts and an account generation; refresh is coalesced and tokens stay in
Keychain. Pagination URLs are checked for the exact API HTTPS origin before
attaching authorization. Redirects are refused for authenticated HTTP traffic.

No runtime path returns sample catalogue data or pretends an unimplemented
service operation succeeded. Hardware, account, queue timing and signing remain
integration gates, as recorded in TESTING.md.

Audio interruptions suspend native restarts even when a late Rust event still
says audio is running. Resume requires the system's permission and retained
play intent; a deliberate pause cancels it. Media-service reset constructs a
new AVAudioEngine and source graph. Notifications, routes and actual resumption
have not been tested with AVAudioSession here.

## Existing Jam invite sharing

Jam sharing adds no playback/session operation. The length-delimited
`sf_parse_jam_invite` entry point validates an existing Spotify URL and preserves
its opaque query; it is pure and does not require an engine handle. It neither
creates a Jam nor resolves an invitation. Swift's worker actor creates the QR
with Core Image and nearest-neighbor bitmap scaling. The native sheet shares
the URL/image, and explicit paste/copy controls handle clipboard access. No
invite is persisted or polled. See [JAM.md](JAM.md) for limits and device gates.
