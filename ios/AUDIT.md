# Pre-build audit — 22 October 2026

The native structure passes source inspection: SwiftUI navigation, lists,
forms, system sheets, SF Symbols and native audio routes are used throughout.
**A rendered-UI pass has not been established.** This Windows environment has
no Apple SDK, Xcode, iOS simulator or connected iPhone. No browser recreation
or fabricated screenshot was used as evidence.

The audit found and repaired 11 groups of issues: seven P1 and four P2.
Two audio defects were reproduced with failing Rust regression tests before
repair. Other repairs have source/syntax coverage, with Apple-platform and
live-account verification still required. This is an audited source candidate,
not a verified sideloadable release. Use [TESTING.md](TESTING.md) for the full
record and [README.md](README.md) for feature limitations and setup.

The subsequent Jam-sharing addition is described in [JAM.md](JAM.md). It adds
sharing/QR generation for an invite already obtained from Spotify; it does
not add Jam creation, hosting or joining to the player. The verification
totals below include those additions, with native verification still pending.

## Findings and repairs

| ID / priority | Finding and user impact | Repair | Evidence / limit |
| --- | --- | --- | --- |
| F01 / P1 | A fixed five-button transport row could exceed a compact phone's content width. Collection artwork/actions also left too little room at accessibility text sizes. | Transport now selects a two-row fallback; collection heading and actions stack at large text sizes. The mini player stacks controls, limits its compact title, and is inset inside each tab's content. Icon sizing is capped locally; text retains Dynamic Type. | Source: `Spotifast/PlayerView.swift`, `CollectionView.swift`, `SpotifastApp.swift`. Native size/render tests added, not run. Tab/keyboard/safe-area interaction remains unverified. |
| F02 / P1 | “Add to playlist” in the full player requested another sheet from the already-presenting root. Root-owned error alerts could also be hidden behind sheets. | Each item menu owns its picker. The visible presentation owns error alerts through `StoreErrorPresenter`. | Source: `Components.swift` and modal presentation sites. Requires simulator checks of nested presentation, dismissal and error alerts. |
| F03 / P1 | A late browser callback, account lookup or failed old command could persist authorization or put the old account's state back after sign-out. HTTP task enumeration could cancel a new account's requests. | Authorization captures an epoch before opening the browser; callback continuations complete once; refresh waiters recheck the epoch. Sign-out cancels registered actions, replaces the old HTTP session, closes presentations, and guards delayed state/credential writes. | Source: `Authentication.swift`, `SpotifyAPI.swift`, `AppStore.swift`. Epoch helper XCTest added but not executed. No live sign-out/account-switch test has run. |
| F04 / P1 | A stopped iOS render consumer could leave the decoder waiting indefinitely on a full PCM ring, preventing pause from completing. | Pause preempts the writer and reaches the player directly; the sink also has a two-second no-progress timeout. Native interruption pause bypasses pending playback commands. | `pause_releases_a_decoder_when_native_output_has_stopped` failed before the repair and passed after it. `stalled_native_output_has_a_bounded_decoder_wait` passes. These execute real sink/buffer code without Spotify or AVAudioSession. |
| F05 / P1 | The next render callback after a flush discarded all published audio, including replacement samples already decoded after the seek/skip. This could cut the beginning of a track. | Each stereo frame carries the decoder's captured epoch. Rendering discards only stale epochs, including a late old packet, and keeps replacement samples. The fixed sample/tag payload is 128 KiB on arm64. | `flushing_old_audio_keeps_the_first_samples_of_its_replacement` returned silence before repair and exact replacement samples afterward. The late-old-packet test and producer/consumer stress test pass. Audible transitions remain untested. |
| F06 / P1 | The final engine event could arrive inside the optimistic UI hold and be discarded forever, leaving stale play/pause/queue state. | A final snapshot is requested when the hold expires. Device/queue revisions reject stale responses; command targets are captured; delayed errors cannot restore an earlier account. Loss of local active-device status clears local controls. | Source: `AppStore.swift`. Real rapid command sequences and Spotify acknowledgement timing still need integration tests. |
| F07 / P1 | Late audio events could reactivate output during an interruption. A denied/duplicate interruption-end notification retained stale resume intent. Media-service reset reused the old engine. | An interruption gate blocks native restart until permitted play intent. User pause cancels automatic resume. A reset recreates AVAudioEngine and its source graph. Repeated stopped snapshots no longer repeatedly deactivate the audio session. | Source: `AudioOutput.swift`, `AudioInterruptionGate.swift`; decision tests added, not executed. Calls, Siri, headphone removal, route changes and service reset require hardware testing. |
| F08 / P2 | Obsolete catalogue requests could finish a newer loading state or replace its rows, particularly when returning to the same search/library selection. Artwork completion could also race view reuse. | Request tickets own results/errors/spinners; obsolete tasks are ignored. Artwork checks cancellation again before assigning and has a resource timeout. | Source: `RequestGate.swift`, `BrowseViews.swift`, `CollectionView.swift`, `Artwork.swift`. Request helper XCTest added, not executed. |
| F09 / P2 | Album pagination occupied the playback command chain; pending albums and queue metadata could survive device/account/queue changes. | Library work is separate from playback ordering. Album fetches retain account/device/edit revisions, detect repeated pages, and append only after all pages succeed. Queue metadata follows actual rows; Rust also enforces local active-device state for queue mutation. | Source: `CollectionView.swift`, `AppStore.swift`, `Rust/src/engine.rs`. Queue occurrence-folding tests pass; actual Spirc transfer/rewrite/partial acceptance remains unverified. |
| F10 / P2 | Unsupported lyrics could leave a permanent spinner, out-of-order lyrics could replace the newer request, read-only playlist pages could look blank, and repeated save taps could queue duplicate writes. | Lyrics have a visible failure state and a latest-request ticket. Playlist picker explains the lack of editable playlists; picker/editor writes disable repeat submission. Player volume follows confirmed state and seek supports VoiceOver adjustment. | Source: `SettingsView.swift`, `CollectionView.swift`, `PlayerView.swift`, `Rust/src/engine.rs`. Live lyrics, VoiceOver and playlist failure/retry behavior need testing. |
| F11 / P2 | Build checks covered only the simulator path and had no native layout artifacts. The test-host path also used an unnecessary bundle-folder expansion. | The project uses the explicit iOS test-host executable path. The Mac script builds Debug simulator and unsigned Release arm64 phone targets, then saves XCTest results and native render attachments. All new Swift sources are included in the generated project. | Deterministic generation, OpenStep parsing, source references and shell syntax pass. No `xcodebuild`, Apple linker or XCTest result exists yet. |

P1 means major functional/platform impact; P2 means a smaller failure or a
workaround exists. No confirmed P0 source defect remains from the checks run;
this does not establish that the Apple SDK build has no blockers.

## Native UI assessment

| Dimension | Source inspection | Native evidence still needed |
| --- | --- | --- |
| Accessibility | Semantic labels, native controls, 44-point icon hit frames, scalable text, compact alternatives and seek adjustment are present. | VoiceOver focus/action results, actual target bounds, largest text on every screen and accessible error presentation. |
| Performance | Native rendering, paged data, bounded PCM, background DSP and bounded artwork storage are retained. No visualizer or browser loop was added. | Instruments allocation/CPU/energy profiles and stable memory over long playback. |
| Appearance/theming | Semantic surfaces/text and light/dark accent variants are used; system/light/dark/black preferences remain. | Actual contrast, materials, selected states, black-theme list surfaces and all loading/error states. |
| Platform conformance | SwiftUI tabs/navigation/forms, system authentication, native menus/sheets and route picker are present. | Nested sheet/alert behavior, keyboard avoidance, drag/swipe editing and navigation restoration. |
| Adaptivity | Small-width transport fallback, large-text collection/mini-player layouts, scrolling player and tab-content inset are implemented. This is an iPhone-only target. | Small/large phones in portrait and landscape; RTL, keyboard and safe-area interactions. |

No rendered UI health score is assigned: these five dimensions cannot be
scored as observed device behavior from source alone. The existing visual
direction was preserved. No unrelated redesign or new app settings were added.

Useful foundations retained: native semantic colors and text styles, explicit
empty/failure states, occurrence identities for duplicate queue songs, an
allocation/lock-free render path, account-scoped persistence, and real Spotify
failure reporting. There is no substitute playback/catalogue implementation.

## Checks completed on this host

- 42 Rust tests pass, including DSP, ABI, queue event folding, FIFO stress,
  interrupted-output preemption, stalled-output timeout, flush publication,
  and invite validation/opaque query preservation.
- Rust Clippy passes with `-D warnings`; formatting passes for iOS and desktop.
  The host reports incremental-cache hard-link fallback warnings, not code lints.
- The actual Windows static library builds. It is not an Apple binary.
- The project parser resolves both targets and every referenced source; the
  generated project matches 18 app files and three test files.
- All 21 Swift files parse with the Swift grammar. This is syntax validation,
  not Swift compiler/Apple SDK type checking.
- Property lists, scheme XML, asset JSON, opaque 1024-pixel icon, dependency
  source policy and macOS shell syntax pass. Shell scripts have LF endings.

The five native layout methods cover compact transport, a long collection
heading, mini-player size, a QR card and native render attachments. Fourteen
other Swift methods cover parsing, authorization/state helpers, a unique
temporary Keychain item and QR decode/pixel checks.
**None of these 19 XCTest methods has executed here.**
Model/helper tests do not prove the whole account/audio lifecycle. Layout size
assertions do not prove full-screen visibility or button hit testing.

## Before sideloading

1. On the Mac, run `bash ios/scripts/bootstrap-macos.sh`, then
   `SIMULATOR='an installed iPhone simulator name' bash ios/scripts/test-macos.sh`.
   Fix any SDK/compiler/link errors and failing tests before signing. Both the
   simulator and Release arm64 build must succeed. The script does not install
   or provision a phone.
2. Open the timestamped `ios/build/*.xcresult` in Xcode. Inspect the actual
   transport/mini-player render attachments. Keep review captures outside Git.
3. Run the app on a small and a large iPhone simulator. Check every row below.
   These are required manual acceptance checks, not previously passed results.
4. Only after the native build/UI checks, sign with your own team and test a
   real Premium account on the phone. Verify local playback, Connect transfers,
   queue rules, interruptions, locked playback and battery use as listed in
   [TESTING.md](TESTING.md). The port's custom Spotify app/streaming grant
   combination has not been validated with an account.

| Screen/flow | Cases | Acceptance |
| --- | --- | --- |
| Sign in | Small portrait/landscape, keyboard open, largest text, cancel/deny browser | Client ID and sign-in remain reachable by scrolling; cancel returns to an actionable form; no stale callback signs in after sign-out. |
| All four tabs | Mini player visible, long title/device name, accessibility5, VoiceOver | Tab bar remains visible/hittable; mini player opens the full player and its two controls remain reachable; list content scrolls above it. |
| Full player | 320-point width and short landscape height; long track/artist names; RTL | Five transport actions remain inside the screen; fallback rows fit; art and labels scroll; seek/volume/route/queue controls remain reachable. |
| Collections/library | Long album/playlist/artist names, largest text, empty/error pages, pagination | Heading wraps; Play/save/menu/Queue album never overlap; cancelled reads do not overwrite newer rows or leave spinners stuck. |
| Sheets and menus | Player → item menu → playlist picker; player → queue/device sheet; playlist editor | Exactly one intended presentation opens; Done/Cancel work; failed writes show an alert on the visible sheet; controls re-enable after failure. |
| Queue | Duplicate songs, reorder/delete/clear, fast next/skip, transfer away while open | Only the active local player offers editing; duplicates remain distinct; accepted remote additions survive refresh; pending album fetch is cancelled by clear/sign-out/device change. |
| Themes/accessibility | Light/dark/black; largest text; VoiceOver; Reduce Motion | Text remains legible; focus order and action names are useful; no unlabeled icon action or clipped critical control. |

Remaining release gates: Apple compilation and XCTest (P0 validation gate),
native full-screen/UI acceptance and live Spotify playback/Connect (P1),
physical routes/background/interruption behavior (P1), and measured memory,
CPU and energy use (P1 for the lightweight-product goal). These are unverified
areas, not claims of confirmed defects. Features explicitly listed as not
ported in the README remain absent; the audit has not simulated them.

Apple references used for these repairs:
[ViewThatFits](https://developer.apple.com/documentation/swiftui/viewthatfits),
[UIHostingController](https://developer.apple.com/documentation/swiftui/uihostingcontroller),
[audio interruptions](https://developer.apple.com/documentation/AVFAudio/handling-audio-interruptions),
[media-service reset](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification).

For further UI work, prioritize `$impeccable adapt` for any observed layout
failure and `$impeccable harden` for presentation/state failures; finish with
`$impeccable polish` after real screenshots and interaction checks are available.
