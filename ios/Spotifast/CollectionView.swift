import SwiftUI

struct CollectionView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: SpotifyItem
    @State private var rows: [ItemRow] = []
    @State private var next: String?
    @State private var loading = false
    @State private var failure: String?
    @State private var saved: Bool?
    @State private var edit = false
    @State private var requests = RequestGate()
    @State private var queuing = false
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    CollectionHeading(item: item)
                    if !item.description.isEmpty { Text(item.description.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)).font(.footnote).foregroundStyle(.secondary).lineLimit(4) }
                    let actions = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                    actions {
                        if item.kind != "artist" && item.kind != "show" {
                            Button { store.play(item) } label: { Label("Play", systemImage: "play.fill").frame(minHeight: 44) }.buttonStyle(.borderedProminent)
                        }
                        HStack {
                            Button { store.perform { let current = try await store.api.membership(item.uri); try await store.api.save(item.uri, saved: !current); saved = !current } } label: { Image(systemName: saved == true ? "checkmark.circle.fill" : "plus.circle").font(.title2).frame(width: 44, height: 44).dynamicTypeSize(...DynamicTypeSize.xxxLarge) }.accessibilityLabel(saved == true ? "Remove from library" : "Save to library")
                            Spacer(minLength: 0)
                            ItemMenu(item: item)
                        }
                    }
                    if item.kind == "album" {
                        Button { Task { await queueAlbum() } } label: { Label(queuing ? "Preparing album…" : "Queue album", systemImage: "text.badge.plus").frame(minHeight: 44) }.disabled(queuing)
                    }
                }.padding(.vertical, 12)
            }
            if let failure { Text(failure).foregroundStyle(.secondary); Button("Try again") { Task { await load(reset: rows.isEmpty) } } }
            if loading && rows.isEmpty { ProgressView("Loading collection") }
            if rows.isEmpty && !loading && failure == nil { ContentUnavailableView("No items available", systemImage: "music.note.list", description: Text("Spotify may limit this collection for your app or account.")) }
            Section(item.kind == "artist" ? "Releases" : item.kind == "show" ? "Episodes" : "Tracks") {
                ForEach(rows) { row in
                    if row.item.isAudio { MusicRow(item: row.item) { store.play(row.item, context: item.kind == "show" ? nil : item, offset: item.kind == "show" ? nil : row.position) } }
                    else { NavigationLink { CollectionView(item: row.item) } label: { ItemSummary(item: row.item) } }
                }
                if next != nil { LoadMore(loading: loading) { Task { await load(reset: false) } } }
            }
        }
        .navigationTitle(item.kind.capitalized).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if item.kind == "playlist", item.owner == store.profile?.id || item.collaborative {
                Menu("Edit") {
                    if item.owner == store.profile?.id { Button("Playlist details") { edit = true } }
                    NavigationLink("Playlist items") { PlaylistItemsEditor(item: item) }
                }
            }
        }
        .sheet(isPresented: $edit) { NavigationStack { PlaylistEditor(item: item) }.environmentObject(store).modifier(StoreErrorPresenter()) }
        .task { await load(reset: true); do { saved = try await store.api.membership(item.uri) } catch { } }
        .refreshable { await load(reset: true, fresh: true) }
    }
    private func load(reset: Bool, fresh: Bool = false) async {
        if loading && !reset { return }
        let ticket = requests.begin(); loading = true; failure = nil
        defer { if requests.accepts(ticket) { loading = false; requests.finish(ticket) } }
        do {
            let page = try await store.api.collection(item, next: reset ? nil : next, fresh: fresh)
            try Task.checkCancellation(); guard requests.accepts(ticket) else { return }
            rows = reset ? page.rows : rows + page.rows; next = page.next
        } catch is CancellationError { } catch { if requests.accepts(ticket) { failure = error.localizedDescription } }
    }
    private func queueAlbum() async {
        // Collect all pages before adding anything. A failed page cannot append
        // a partial album, and duplicate tracks retain album order.
        guard !queuing else { return }; queuing = true; defer { queuing = false }
        let account = store.profile?.id; let device = store.playback.deviceID; let revision = store.queueEditRevision
        do {
            var page = try await store.api.collection(item)
            var all = page.rows.map(\.item)
            var visited: Set<String> = []
            while let next = page.next {
                guard account == store.profile?.id, revision == store.queueEditRevision else { return }
                guard device == store.playback.deviceID else { throw AppError.message("Playback device changed. Queue the album again on the selected device.") }
                guard visited.insert(next).inserted else { throw AppError.message("Spotify repeated an album page. Try again.") }
                try Task.checkCancellation(); page = try await store.api.collection(item, next: next); all += page.rows.map(\.item)
            }
            try Task.checkCancellation()
            guard account == store.profile?.id, revision == store.queueEditRevision else { return }
            guard device == store.playback.deviceID else { throw AppError.message("Playback device changed. Queue the album again on the selected device.") }
            store.addToQueue(all)
        } catch is CancellationError { } catch { if account == store.profile?.id { failure = error.localizedDescription } }
    }
}

struct CollectionHeading: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let item: SpotifyItem
    var body: some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            Artwork(url: item.image, size: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.kind.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(item.name).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PlaylistPicker: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let item: SpotifyItem
    @State private var rows: [ItemRow] = []
    @State private var next: String?
    @State private var loading = false
    @State private var failure: String?
    @State private var submitting = false
    private var editable: [ItemRow] { rows.filter { $0.item.owner == store.profile?.id || $0.item.collaborative } }
    var body: some View {
        List {
            if loading { ProgressView("Loading playlists") }
            if let failure { Text(failure); Button("Try again") { Task { await load() } } }
            ForEach(editable) { row in
                Button {
                    guard !submitting else { return }; submitting = true
                    store.perform { defer { submitting = false }; try await store.api.add(item, to: row.item); dismiss() }
                } label: { ItemSummary(item: row.item) }.disabled(submitting)
            }
            if next != nil { LoadMore(loading: loading) { Task { await load() } } }
            if !loading && editable.isEmpty && next == nil && failure == nil { Text("No editable playlists found. Create a playlist in your Library first.") }
        }.navigationTitle("Add to playlist").toolbar { Button("Cancel") { dismiss() } }.task { await load() }
    }
    private func load() async {
        guard !loading else { return }; loading = true; failure = nil; defer { loading = false }
        do { let page = try await store.api.library(.playlists, next: next); try Task.checkCancellation(); rows += page.rows; next = page.next } catch is CancellationError { } catch { failure = error.localizedDescription }
    }
}

struct PlaylistEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let item: SpotifyItem
    @State private var name = ""
    @State private var description = ""
    @State private var isPublic = false
    @State private var ready = false
    @State private var submitting = false
    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Description", text: $description, axis: .vertical)
            Toggle("Public", isOn: $isPublic)
            if !ready { ProgressView("Loading playlist details") }
        }.navigationTitle("Edit playlist").scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard !submitting else { return }; submitting = true
                    let title = name; let details = description; let visibility = isPublic
                    store.perform { defer { submitting = false }; try await store.api.editPlaylist(item, name: title, description: details, isPublic: visibility); dismiss() }
                }.disabled(!ready || submitting || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .task {
            do { let json = try await store.api.request("playlists/\(item.resourceID)"); name = json["name"].string ?? item.name; description = json["description"].string ?? ""; isPublic = json["public"].bool ?? false; ready = true } catch { store.error = error.localizedDescription }
        }
    }
}
