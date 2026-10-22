import Foundation

enum PlaylistEdits {
    static func reorder(rows: [ItemRow], from: IndexSet, to: Int, endOffset: Int, snapshot: String) throws -> JSON? {
        guard from.count == 1, let source = from.first, rows.indices.contains(source), (0...rows.count).contains(to),
              !snapshot.isEmpty, endOffset >= (rows.last?.position ?? -1) + 1 else { throw AppError.message("Reload this playlist before moving a song") }
        if to == source || to == source + 1 { return nil }
        let before = to == rows.count ? endOffset : rows[to].position
        return .object(["range_start": .number(Double(rows[source].position)), "insert_before": .number(Double(before)), "range_length": .number(1), "snapshot_id": .string(snapshot)])
    }
    static func removeAllCopies(_ rows: [ItemRow], snapshot: String) throws -> JSON {
        let uris = Set(rows.map(\.item.uri)).sorted()
        guard !snapshot.isEmpty, !uris.isEmpty, uris.count <= 100, rows.allSatisfy({ $0.item.isAudio && !$0.item.uri.hasPrefix("spotify:local:") }) else { throw AppError.message("Select up to 100 songs or episodes to remove") }
        return .object(["items": .array(uris.map { .object(["uri": .string($0)]) }), "snapshot_id": .string(snapshot)])
    }
}
