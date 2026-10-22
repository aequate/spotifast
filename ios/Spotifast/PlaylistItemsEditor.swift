import SwiftUI

struct PlaylistItemsEditor: View {
    @EnvironmentObject private var store: AppStore
    let item: SpotifyItem
    @State private var rows: [ItemRow] = []
    @State private var snapshot = ""
    @State private var next: String?
    @State private var endOffset = 0
    @State private var loading = false
    @State private var submitting = false
    @State private var failure: String?
    @State private var removing: [ItemRow] = []
    @State private var confirmRemoval = false
    @State private var requests = RequestGate()

    var body: some View {
        List {
            Section {
                Text("Drag a handle to change the playlist order. Removing a song or episode removes every copy of it from this playlist.").font(.footnote).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.secondary); Button("Reload playlist") { Task { await load(reset: true) } } }
            if loading { ProgressView("Loading playlist") }
            if submitting { ProgressView("Saving playlist") }
            Section("Playlist order") {
                ForEach(rows) { row in ItemSummary(item: row.item) }
                    .onMove { offsets, destination in
                        mutate {
                            if let body = try PlaylistEdits.reorder(rows: rows, from: offsets, to: destination, endOffset: endOffset, snapshot: snapshot) {
                                try await store.api.updatePlaylistItems(item, body: body, method: "PUT")
                            }
                        }
                    }
                    .onDelete { offsets in
                        removing = offsets.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
                        confirmRemoval = !removing.isEmpty
                    }
                    .moveDisabled(submitting || loading || snapshot.isEmpty)
                    .deleteDisabled(submitting || loading || snapshot.isEmpty)
                if next != nil { LoadMore(loading: loading) { Task { await load(reset: false) } }.disabled(submitting) }
                if rows.isEmpty && !loading && failure == nil { Text("No editable songs or episodes in this playlist") }
            }
        }
        .navigationTitle("Edit playlist items").navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        .confirmationDialog("Remove all copies of the selected songs or episodes?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove all copies", role: .destructive) {
                let selected = removing; let revision = snapshot
                mutate { try await store.api.updatePlaylistItems(item, body: PlaylistEdits.removeAllCopies(selected, snapshot: revision), method: "DELETE") }
            }
            Button("Cancel", role: .cancel) { removing = [] }
        } message: { Text("Spotify removes these items by URI, including copies outside the loaded page. This cannot be undone in Spotifast.") }
        .task { await load(reset: true) }
        .refreshable { if !submitting { await load(reset: true) } }
    }

    private func mutate(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !submitting, !loading, !snapshot.isEmpty else { return }
        submitting = true; failure = nil
        store.perform {
            defer { submitting = false }
            do { try await operation(); await load(reset: true) }
            catch is CancellationError { }
            catch { snapshot = ""; failure = error.localizedDescription }
        }
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        let ticket = requests.begin(); loading = true; failure = nil
        defer { if requests.accepts(ticket) { loading = false; requests.finish(ticket) } }
        do {
            let header = try await store.api.request("playlists/\(item.resourceID)", fresh: true)
            guard let revision = header["snapshot_id"].string, !revision.isEmpty else { throw AppError.message("Spotify did not return the playlist revision") }
            if !reset && revision != snapshot { throw AppError.message("This playlist changed. Reload it before editing.") }
            let page = try await store.api.collection(item, next: reset ? nil : next, fresh: true)
            let after = try await store.api.request("playlists/\(item.resourceID)", fresh: true)
            try Task.checkCancellation(); guard requests.accepts(ticket) else { return }
            guard after["snapshot_id"].string == revision else { throw AppError.message("This playlist changed while loading. Reload it before editing.") }
            guard reset || rows.count + page.rows.count <= 10_000 else { throw AppError.message("This editor holds up to 10,000 items at a time") }
            rows = reset ? page.rows : rows + page.rows
            snapshot = revision; next = page.next; endOffset = page.endOffset
        } catch is CancellationError { }
        catch { if requests.accepts(ticket) { snapshot = ""; failure = error.localizedDescription } }
    }
}
