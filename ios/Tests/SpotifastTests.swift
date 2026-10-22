import XCTest
@testable import Spotifast

final class SpotifastTests: XCTestCase {
    func testRustReportsRealIOSVersionForClientTokens() {
        let info = RustBridge.platformInfo()
        XCTAssertEqual(info["os"].string, "ios")
        XCTAssertTrue(["aarch64", "x86_64"].contains(info["arch"].string ?? ""))
        let version = info["osVersion"].string ?? "0"
        XCTAssertNotEqual(version, "0")
        XCTAssertEqual(Int(version.split(separator: ".").first ?? "0"), ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
    func testTokenFormKeepsLiteralPlusAndSeparators() {
        let encoded = String(decoding: TokenForm.encode(["refresh_token": "a+b&c=d"]), as: UTF8.self)
        XCTAssertTrue(encoded.contains("%2B"))
        XCTAssertTrue(encoded.contains("%26"))
        XCTAssertTrue(encoded.contains("%3D"))
        XCTAssertFalse(encoded.contains("+"))
    }
    func testDevelopmentModeMissingProductIsUnknownRatherThanFree() throws {
        let profile = try Profile(.object(["id": .string("test-account")]))
        XCTAssertNil(profile.premium)
    }
    func testModernAndLegacyPlaylistRowsKeepRepeatedOccurrences() throws {
        let item = #"{"uri":"spotify:track:abc","name":"A","type":"track","duration_ms":1234}"#
        let data = Data("{\"offset\":30,\"items\":[{\"item\":\(item)},{\"track\":\(item)},{\"item\":null}]}".utf8)
        let page = ItemPage(try JSONDecoder().decode(JSON.self, from: data))
        XCTAssertEqual(page.rows.count, 2)
        XCTAssertEqual(page.rows.map(\.position), [30, 31])
        XCTAssertNotEqual(page.rows[0].id, page.rows[1].id)
    }
    func testUnavailableAndLocalTracksDoNotBecomePlayable() throws {
        for extra in [#""is_playable":false"#, #""is_local":true"#, #""restrictions":{"reason":"market"}"#] {
            let value = try JSONDecoder().decode(JSON.self, from: Data("{\"uri\":\"spotify:track:abc\",\"name\":\"A\",\(extra)}".utf8))
            XCTAssertEqual(SpotifyItem(value)?.playable, false)
        }
    }
    func testPKCERejectsForeignCallbacksAndSeparatesGrants() throws {
        let flow = try PKCE()
        XCTAssertEqual(flow.verifier.count, 43)
        XCTAssertEqual(flow.challenge.count, 43)
        let accepted = URL(string: "spotifast-ios://oauth/callback?code=ok&state=\(flow.state)")!
        XCTAssertEqual(try flow.code(from: accepted), "ok")
        for bad in ["spotifast-ios://evil/callback?code=ok&state=\(flow.state)", "spotifast-ios://oauth/callback?code=ok&state=wrong", "spotifast-ios://oauth/callback?code=ok&state=\(flow.state)&state=\(flow.state)", "spotifast-ios://oauth/callback?code=one&code=two&state=\(flow.state)"] { XCTAssertThrowsError(try flow.code(from: URL(string: bad)!)) }
        for grant in [Grant.web, .playback] {
            let url = try flow.url(clientID: String(repeating: "a", count: 32), grant: grant)
            let scope = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "scope" }!.value!
            XCTAssertEqual(scope.contains("streaming"), grant == .playback)
        }
    }
    func testPaginationNeverSendsBearerToAnotherHost() throws {
        for bad in ["https://evil.test/v1/me", "https://api.spotify.com.evil.test/v1/me", "https://api.spotify.com:444/v1/me", "https://user:password@api.spotify.com/v1/me", "https://api.spotify.com/outside"] { XCTAssertThrowsError(try SpotifyAPI.url(bad)) }
        XCTAssertEqual(try SpotifyAPI.url("me/player").host, "api.spotify.com")
    }
    func testNativeKeychainRoundTrip() throws {
        let name = "test-" + UUID().uuidString
        defer { try? Keychain.delete(name) }
        try Keychain.write(Data("temporary-test-grant".utf8), name: name)
        XCTAssertEqual(try Keychain.read(name), Data("temporary-test-grant".utf8))
        try Keychain.write(Data("replacement".utf8), name: name)
        XCTAssertEqual(try Keychain.read(name), Data("replacement".utf8))
        try Keychain.delete(name)
        XCTAssertNil(try Keychain.read(name))
    }

    func testReplacedRequestCannotFinishTheNewRequestsSpinner() {
        var requests = RequestGate()
        let old = requests.begin(); let current = requests.begin()
        requests.finish(old)
        XCTAssertFalse(requests.accepts(old))
        XCTAssertTrue(requests.accepts(current))
        requests.cancel()
        XCTAssertFalse(requests.accepts(current))
    }
    func testSignOutEpochRejectsDelayedAuthorization() {
        var account = AccountEpoch(); let browserTicket = account.value
        XCTAssertTrue(account.accepts(browserTicket))
        account.invalidate()
        XCTAssertFalse(account.accepts(browserTicket))
        XCTAssertTrue(account.accepts(account.value))
    }
    func testInterruptionCannotResumeWithoutSystemPermissionAndFreshPlayIntent() {
        var audio = AudioInterruptionGate()
        XCTAssertTrue(audio.canStart)
        audio.begin(wasRunning: true)
        XCTAssertFalse(audio.canStart)
        XCTAssertFalse(audio.end(shouldResume: false))
        XCTAssertFalse(audio.canStart)
        // Duplicate end notifications cannot replay an old resume decision.
        XCTAssertFalse(audio.end(shouldResume: true))
        audio.playRequested(); XCTAssertTrue(audio.canStart)
        audio.begin(wasRunning: true)
        XCTAssertTrue(audio.end(shouldResume: true))
        XCTAssertFalse(audio.canStart)
        audio.playRequested(); XCTAssertTrue(audio.canStart)
    }
    func testPausingDuringInterruptionCancelsAutomaticResume() {
        var audio = AudioInterruptionGate()
        audio.begin(wasRunning: true); audio.pauseRequested()
        XCTAssertFalse(audio.end(shouldResume: true))
        audio.playRequested(); XCTAssertTrue(audio.canStart)
        audio.pauseRequested(); XCTAssertTrue(audio.canStart)
        audio.cancelResume(); XCTAssertFalse(audio.canStart)
    }
}
