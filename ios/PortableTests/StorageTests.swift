import Foundation
import XCTest
#if canImport(SpotifastLogic)
@testable import SpotifastLogic
#else
@testable import Spotifast
#endif

final class StorageTests: XCTestCase {
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("spotifast-tests-" + UUID().uuidString, isDirectory: true) }

    func testCachePersistsExactPagesAndExpiresWithoutAnyNetworkSubstitute() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = CacheStore(root: root)
        let scope = try await cache.open(account: "listener")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let value: JSON = .object(["items": .array([.null]), "next": .string("https://api.spotify.com/v1/me/tracks?offset=30")])
        try await cache.write(value, key: "library", ttl: 300, scope: scope, now: now)
        let read = await cache.read("library", scope: scope, now: now.addingTimeInterval(299))
        XCTAssertEqual(read, value)
        let nextRun = CacheStore(root: root)
        let reopened = try await nextRun.open(account: "listener")
        let persisted = await nextRun.read("library", scope: reopened, now: now.addingTimeInterval(299))
        XCTAssertEqual(persisted, value)
        let expired = await nextRun.read("library", scope: reopened, now: now.addingTimeInterval(300))
        XCTAssertNil(expired)
    }

    func testCacheNeverLetsOldAccountRequestsRecreateSignedOutMetadata() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = CacheStore(root: root)
        let first = try await cache.open(account: "first")
        try await cache.write(.string("private"), key: "page", ttl: 300, scope: first)
        try await cache.close(clear: true)
        let second = try await cache.open(account: "second")
        try await cache.write(.string("late response"), key: "page", ttl: 300, scope: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
        let old = await cache.read("page", scope: first); let current = await cache.read("page", scope: second)
        XCTAssertNil(old); XCTAssertNil(current)
        XCTAssertNotEqual(first.audioDirectory, second.audioDirectory)
    }

    func testCacheBoundsBytesAndFileCountAndIgnoresOversizedEntries() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = CacheStore(root: root, budget: 1024)
        let scope = try await cache.open(account: "listener")
        for index in 0..<100 { try await cache.write(.string(String(repeating: "x", count: 80)), key: "page-\(index)", ttl: 300, scope: scope) }
        try await cache.write(.string(String(repeating: "x", count: 2000)), key: "oversize", ttl: 300, scope: scope)
        let files = try FileManager.default.contentsOfDirectory(at: scope.directory.appendingPathComponent("metadata"), includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, 1024); XCTAssertLessThanOrEqual(files.count, 64)
        let oversize = await cache.read("oversize", scope: scope); XCTAssertNil(oversize)
    }

    func testCachePolicyExcludesSensitiveAndRealtimeRequests() throws {
        for path in ["me", "me/player", "me/player/devices", "me/player/queue", "me/library/contains?uris=x", "me/player/recently-played"] { XCTAssertNil(CatalogueCachePolicy.ttl(try WebAPIAddress.url(path))) }
        for path in ["me/tracks?limit=30", "playlists/test/items", "albums/test/tracks"] { XCTAssertEqual(CatalogueCachePolicy.ttl(try WebAPIAddress.url(path)), 300) }
    }

    func testMutationsInvalidateMetadataWithoutDeletingTheAudioCache() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = CacheStore(root: root); let scope = try await cache.open(account: "listener")
        try await cache.write(.bool(true), key: "page", ttl: 300, scope: scope)
        try await cache.invalidateMetadata(scope: scope)
        let value = await cache.read("page", scope: scope); XCTAssertNil(value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scope.audioDirectory.path))
        try await cache.write(.bool(false), key: "page", ttl: 300, scope: scope)
        let replacement = await cache.read("page", scope: scope); XCTAssertEqual(replacement, .bool(false))
    }

    func testPreferencesUpgradeMissingFieldsWithoutLosingExistingValues() throws {
        let partial = Data(#"{"theme":"black","bitrate":320,"futureSetting":true}"#.utf8)
        let preferences = try JSONDecoder().decode(Preferences.self, from: partial)
        XCTAssertEqual(preferences.theme, "black"); XCTAssertEqual(preferences.bitrate, 320)
        XCTAssertEqual(preferences.bands.count, 10); XCTAssertEqual(preferences.deviceID.count, 32)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }

    func testPreferencesRejectInvalidArraysRangesQualityAndDeviceIDs() {
        for data in [#"{"bands":[0]}"#, #"{"bitrate":999}"#, #"{"balance":2}"#, #"{"preamp":100}"#, #"{"deviceID":"../other"}"#, #"{"theme":"invalid"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(Preferences.self, from: Data(data.utf8)))
        }
    }

    func testActualAtomicPreferenceAndAccountScopedSessionRoundTrip() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = PreferencesFile(directory: root)
        var preferences = Preferences(); preferences.theme = "dark"
        try await file.save(preferences)
        let restored = try await file.load(); XCTAssertEqual(restored, preferences)
        let session: JSON = .object(["account": .string("listener"), "uri": .string("spotify:track:test"), "position_ms": .number(1234)])
        try await file.saveSession(session)
        let mine = try await file.session(account: "listener"); let foreign = try await file.session(account: "other")
        XCTAssertEqual(mine, session); XCTAssertNil(foreign)
        try await file.clearSession()
        let deleted = try await file.session(account: "listener"); XCTAssertNil(deleted)
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(contents, ["preferences.json"])
    }
}
