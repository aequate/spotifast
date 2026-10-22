import Foundation
import XCTest
#if canImport(SpotifastLogic)
@testable import SpotifastLogic
#else
@testable import Spotifast
#endif

final class LogicTests: XCTestCase {
    func testJSONRoundTripsNullableAndNestedSpotifyResponses() throws {
        for value in [JSON.null, .bool(true), .number(1234), .string("عربي 🎵 +%&"), .array([.null, .string("track")]), .object(["items": .array([.null]), "next": .null])] {
            XCTAssertEqual(try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(value)), value)
        }
        for number in [Double.infinity, -.infinity, .nan, Double(Int.max), Double(Int.min)] { XCTAssertNil(JSON.number(number).int) }
    }

    func testFormEncodingRoundTripsAllPrintableASCIIAndUnicode() throws {
        for text in [(32...126).compactMap(UnicodeScalar.init).map(String.init).joined(), "عربي 🎵", "a+b&c=d?e#f%g\n"] {
            let body = String(decoding: TokenForm.encode(["refresh_token": text]), as: UTF8.self)
            let decoded = URLComponents(string: "https://example.test/?" + body.replacingOccurrences(of: "+", with: " "))
            XCTAssertEqual(decoded?.queryItems?.first?.value, text)
        }
    }

    func testCallbacksAcceptExactlyOneStateAndCodeAtTheRegisteredAddress() throws {
        let prefix = "spotifast-ios://oauth/callback?state=state&code="
        XCTAssertEqual(try OAuthCallback.code(from: XCTUnwrap(URL(string: prefix + "a%2Bb%3D")), state: "state"), "a+b=")
        for address in [prefix, prefix + "x&code=y", prefix + "x&state=state", prefix + "x&error=denied", prefix + "x#fragment", prefix + "%00", "spotifast-ios://oauth:443/callback?state=state&code=x", "spotifast-ios://user@oauth/callback?state=state&code=x", "https://oauth/callback?state=state&code=x", "spotifast-ios://oauth/other?state=state&code=x", prefix + String(repeating: "x", count: 4097)] {
            XCTAssertThrowsError(try OAuthCallback.code(from: XCTUnwrap(URL(string: address)), state: "state"), address)
        }
        XCTAssertThrowsError(try OAuthCallback.code(from: XCTUnwrap(URL(string: prefix + "x")), state: "another"))
    }

    func testPaginationCannotMoveBearerOutsideTheSpotifyAPI() throws {
        for path in ["me/tracks?offset=30", "https://api.spotify.com/v1/playlists/test/items?offset=30"] {
            XCTAssertEqual(try WebAPIAddress.url(path).host, "api.spotify.com")
        }
        for path in ["https://evil.test/v1/me", "https://api.spotify.com.evil.test/v1/me", "https://user@api.spotify.com/v1/me", "https://api.spotify.com:444/v1/me", "https://api.spotify.com/outside", "https://api.spotify.com/v1/../outside", "https://api.spotify.com/v1/me#fragment"] {
            XCTAssertThrowsError(try WebAPIAddress.url(path), path)
        }
    }

    func testPagePositionsKeepDuplicateOccurrencesAndNullSlots() throws {
        let track: JSON = .object(["uri": .string("spotify:track:abc"), "name": .string("A"), "type": .string("track")])
        let page = ItemPage(.object(["offset": .number(30), "items": .array([.object(["item": track]), .null, .object(["track": track])])]))
        XCTAssertEqual(page.rows.map(\.position), [30, 32])
        XCTAssertNotEqual(page.rows.first?.id, page.rows.last?.id)
    }

    func testUnavailableAudioIsNotOfferedAsPlayable() throws {
        for restriction in [["is_local": JSON.bool(true)], ["is_playable": .bool(false)], ["restrictions": .object(["reason": .string("market")])]] {
            let value = restriction.merging(["uri": .string("spotify:track:abc"), "name": .string("A")]) { a, _ in a }
            XCTAssertFalse(try XCTUnwrap(SpotifyItem(.object(value))).playable)
        }
        XCTAssertNil(try Profile(.object(["id": .string("listener")])).premium)
    }

    func testLateRequestsAndOldAccountsCannotChangeCurrentState() {
        var requests = RequestGate()
        let first = requests.begin(); let second = requests.begin()
        requests.finish(first); XCTAssertTrue(requests.accepts(second)); XCTAssertFalse(requests.accepts(first))
        requests.cancel(); XCTAssertFalse(requests.accepts(second))
        var account = AccountEpoch(); let before = account.value
        account.invalidate(); XCTAssertFalse(account.accepts(before))
    }

    func testInterruptionOrderingNeverStartsWithoutNewIntent() {
        for systemAllows in [false, true] {
            for paused in [false, true] {
                var gate = AudioInterruptionGate()
                gate.begin(wasRunning: true); gate.begin(wasRunning: false)
                if paused { gate.pauseRequested() }
                XCTAssertFalse(gate.canStart)
                XCTAssertEqual(gate.end(shouldResume: systemAllows), systemAllows && !paused)
                XCTAssertFalse(gate.canStart)
                XCTAssertFalse(gate.end(shouldResume: true))
                gate.playRequested(); XCTAssertTrue(gate.canStart)
                gate.cancelResume(); XCTAssertFalse(gate.canStart)
            }
        }
    }
}
