# Jam invitations

Open **Listen → Jam invites**, or **Now playing → Jam invites**.

This port can display, copy and share an invite supplied by Spotify, including
generating and sharing a standard QR image locally. **It cannot create a new
Spotify Jam session, obtain its invitation from Spotify, host it, manage guests
or join it within the librespot player.** Those operations still happen in the
Spotify app. This distinction is visible on the screen, before entering a link.

## Flow

1. Choose **Open Spotify**. In Spotify, start a Jam from its device menu, then
   use **Invite → Share link** and copy the invitation. Spotify requires Premium
   to host. This button opens Spotify; it does not pretend to start a session
   or automatically transfer playback.
2. Return to Spotifast and paste the link using the system paste button or
   the text field. Choose **Show QR and share**.
3. The invitation sheet offers **Share link**, **Copy link** and **Share QR
   image**. Friends can use their camera to open the QR's link in Spotify.
4. When Spotify ends or invalidates the Jam, copy a new invitation from
   Spotify. Spotifast cannot renew an invitation or establish that it is live.

The app accepts HTTPS `open.spotify.com/socialsession/<id>` invitations and
opaque `spotify.link/<id>` short links. It does not visit or expand short links.
A short link can also point to ordinary music, so the sheet explicitly asks
for the link from the Jam's Invite screen. Host/path validation establishes
the address shape, not an active session or permission to join.

## Why creation remains in Spotify

The repository's [capability reference](../docs/_reference/what-spotify-allows.md)
lists Jam as unavailable through the Web API and librespot. The pinned fork
`8c68baf` has no Jam-creation/invite API. Its `Spirc` session-update handler
explicitly leaves Jam handling for future support. The current iOS App Remote
player API also does not expose a Jam-creation operation to reuse here.

Sources checked on 22 October 2026:

- [Spotify's Jam guide](https://support.spotify.com/us/article/jam/) explains
  starting a Jam in Spotify and sharing its invitation/QR.
- [Spotify's API discussion](https://community.spotify.com/forum/en/discussion/6235408/web-api-info-for-jams)
  explains the lack of a Web API operation for Jam and distinguishes potential
  playback SDK support. This is not a promise that every Spotify SDK lacks it.
- [iOS App Remote player API](https://spotify.github.io/ios-sdk/html/Protocols/SPTAppRemotePlayerAPI.html)
  documents the current player operations.
- [Apple's QR generator](https://developer.apple.com/documentation/coreimage/cifilter-swift.class/qrcodegenerator())
  supplies the local image generation.

No guessed private write endpoint, generated session ID, substitute group
queue, embedded Spotify browser or hosted link/QR service was introduced.

## Implementation and limits

- `Rust/src/jam.rs` performs bounded, dependency-free validation. It allows
  only the two exact Spotify hosts, HTTPS, recognized paths and well-formed
  opaque query data. It rejects credentials, explicit ports, lookalike hosts,
  non-invite long URLs, fragments, backslashes, controls and malformed escapes.
- `sf_parse_jam_invite` accepts an explicit byte length, so embedded NUL bytes
  cannot silently truncate the address. It returns the exact trimmed URL and
  an unresolved-short-link flag. It does not start the playback runtime.
- `JamInvite.swift` carries that exact UTF-8 payload to Core Image. It does not
  reconstruct a session from the currently playing track or Connect session ID.
- The QR has a white border of four modules on every side, black/white pixels,
  medium error correction and integer nearest-neighbor scaling. The generated
  image is at most 768 pixels square. The payload is capped at 1,024 bytes for
  bounded generation and practical phone display; an overly long link is
  rejected, never truncated. The full address is preserved even if its on-screen
  label is shortened.
- Rendering runs on a worker actor with software Core Image rendering and
  intermediate caching disabled. Only the visible screen keeps its image.
  No new runtime package, polling task or background service was added.
- The native share sheet sends the actual URL or QR image. An explicit local
  preview avoids fetching invite metadata for display. The app never sends
  an invitation to another person automatically.
- No invite is saved to preferences, Keychain or a disk cache, or logged. The
  pasteboard is read only through the user-triggered system control/paste action.
  **Copy link** explicitly puts text on the local pasteboard for up to one hour;
  it is not placed on Universal Clipboard. Sharing/saving outside the app is
  controlled by the activity the user chooses.
- Opening Spotify requires its app to be installed. The guide link opens the
  system browser. Recipients use Spotify's own join/eligibility flow. The
  port does not claim Jam membership, guest status, local hosting or QR validity.

## Verification

Windows execution: 42 Rust tests pass, including seven new invite/ABI tests.
The new tests cover exact opaque query preservation, parser idempotence,
all 256 appended-host byte cases, all printable ASCII byte values through
percent encoding, size boundaries, deceptive origins, invalid UTF-8 and
embedded NUL. This is bounded exhaustive coverage, not a claim of exhaustive
coverage over all URLs or a live Spotify test.

The project parser and Swift syntax checks include 18 app and three test
sources. **Native compilation, QR generation/decoding and device scanning
have not run here.** `JamInviteTests` adds three Apple-platform methods for
the actual Rust/Swift bridge and exact QR decode/pixel/border checks, including
the 1,024-byte limit. `LayoutTests` adds a compact light/dark QR-card render.
These four new methods are among 19 Swift test methods awaiting Xcode.

On the Mac, run the test workflow in [TESTING.md](TESTING.md), inspect its native
render attachments, then verify on an iPhone:

1. Open the Jam screen from Listen and from the full player. With Spotify
   installed, **Open Spotify** opens it without claiming the Jam has started.
   Without Spotify, the screen explains what is needed and accepts an invite
   already obtained elsewhere.
2. Start a real Jam in Spotify, copy its link, return and paste. Check both a
   full socialsession URL and a Spotify short link. Compare the copied/shared
   URL with the original, including its query. Reject a track URL, lookalike
   host, malformed escape, embedded newline and an oversized address.
3. Scan the displayed QR from a second device. Confirm Spotify opens the
   intended invitation. Share the QR image and scan the shared image as well.
   Ending the Jam must not be reported as an active or newly created session.
4. Test 320-point portrait and short landscape layouts, light/dark/black,
   accessibility5 text, VoiceOver, keyboard avoidance, repeated presentation
   and dismissals, cancelled sharing and a QR rendering failure. All controls
   must remain reachable by scrolling; a QR failure must leave link sharing
   available.
5. Edit or replace the invite after closing the sheet. Confirm the next QR
   encodes the new link. Sign out with the screen open and confirm its
   presentation disappears with the account. Check memory returns after
   dismissal and that no rendering work repeats while idle.

Passing native decode tests will establish image/payload fidelity, not that
Spotify accepts the invitation. Successful real-session joining and scanning
still require the two-device check.
