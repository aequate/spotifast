import Foundation
import XCTest
@testable import SpotifastLogic

final class PlaylistTests: XCTestCase {
    private func rows(_ count: Int) throws -> [ItemRow] {
        try (0..<count).map { position in ItemRow(item: try XCTUnwrap(SpotifyItem(.object(["uri": .string("spotify:track:track\(position)"), "name": .string("Song \(position)"), "type": .string("track")]))), position: position) }
    }
    func testEverySingleRowMoveMatchesTheSpotifyInsertionContract() throws {
        for count in 1...12 {
            let list = try rows(count)
            for source in 0..<count {
                for destination in 0...count {
                    let body = try PlaylistEdits.reorder(rows: list, from: IndexSet(integer: source), to: destination, endOffset: count, snapshot: "revision")
                    if destination == source || destination == source + 1 { XCTAssertNil(body); continue }
                    let request = try XCTUnwrap(body)
                    XCTAssertEqual(request["snapshot_id"].string, "revision")
                    let range = try XCTUnwrap(request["range_start"].int)
                    let before = try XCTUnwrap(request["insert_before"].int)
                    var actual = Array(0..<count); let moved = actual.remove(at: range)
                    actual.insert(moved, at: before > range ? before - 1 : before)
                    var expected = Array(0..<count); expected.remove(at: source)
                    expected.insert(source, at: destination > source ? destination - 1 : destination)
                    XCTAssertEqual(actual, expected)
                }
            }
        }
    }
    func testMovesKeepServerOffsetsWhenNullRowsAreNotDisplayed() throws {
        let initial = try rows(4); let visible = [initial[0], initial[2], initial[3]]
        let move = try XCTUnwrap(PlaylistEdits.reorder(rows: visible, from: IndexSet(integer: 2), to: 1, endOffset: 5, snapshot: "revision"))
        XCTAssertEqual(move["range_start"].int, 3); XCTAssertEqual(move["insert_before"].int, 2)
        let end = try XCTUnwrap(PlaylistEdits.reorder(rows: visible, from: IndexSet(integer: 0), to: 3, endOffset: 5, snapshot: "revision"))
        XCTAssertEqual(end["insert_before"].int, 5)
    }
    func testRemovalNamesItsAllCopiesSemanticsAndDeduplicatesThePayload() throws {
        let list = try rows(2)
        let body = try PlaylistEdits.removeAllCopies([list[0], list[0], list[1]], snapshot: "revision")
        XCTAssertEqual(body["items"].array.count, 2)
        XCTAssertEqual(body["snapshot_id"].string, "revision")
        XCTAssertTrue(body["items"].array.allSatisfy { $0["positions"] == .null })
        XCTAssertThrowsError(try PlaylistEdits.removeAllCopies([], snapshot: "revision"))
        XCTAssertThrowsError(try PlaylistEdits.removeAllCopies(list, snapshot: ""))
    }
    func testInvalidMoveRangesAreRefusedBeforeAnyWrite() throws {
        let list = try rows(4)
        for offsets in [IndexSet(), IndexSet([1, 2]), IndexSet(integer: 4)] {
            XCTAssertThrowsError(try PlaylistEdits.reorder(rows: list, from: offsets, to: 0, endOffset: 4, snapshot: "revision"))
        }
        for destination in [-1, 5] { XCTAssertThrowsError(try PlaylistEdits.reorder(rows: list, from: IndexSet(integer: 0), to: destination, endOffset: 4, snapshot: "revision")) }
        XCTAssertThrowsError(try PlaylistEdits.reorder(rows: list, from: IndexSet(integer: 0), to: 3, endOffset: 4, snapshot: ""))
    }
}
