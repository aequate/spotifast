import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var recent: [ItemRow] = []
    @State private var top: [ItemRow] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var requests = RequestGate()
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Made for listening").font(.title.bold())
                    Text(store.profile.map { "Welcome, \($0.name)." } ?? "Your library, close at hand.").foregroundStyle(.secondary)
                }.padding(.vertical, 12)
                NavigationLink { LibraryView(section: .songs) } label: { Label("Liked Songs", systemImage: "heart.fill") }
                NavigationLink { JamView() } label: { Label("Jam invites", systemImage: "qrcode") }
                Button { store.devicesPresented = true } label: { Label(store.playback.deviceName, systemImage: "hifispeaker") }
            }
            if let failure { Section { Text(failure).foregroundStyle(.secondary); Button("Try again") { Task { await load() } } } }
            if loading && recent.isEmpty && top.isEmpty { ProgressView("Loading your music") }
            if !recent.isEmpty { Section("Recently played") { ForEach(recent) { row in MusicRow(item: row.item) } } }
            if !top.isEmpty { Section("Your most played") { ForEach(top) { row in MusicRow(item: row.item) } } }
        }
        .navigationTitle("Listen")
        .task { if recent.isEmpty && top.isEmpty { await load() } }
        .refreshable { await load() }
    }
    private func load() async {
        let ticket = requests.begin()
        loading = true; failure = nil
        defer { if requests.accepts(ticket) { loading = false; requests.finish(ticket) } }
        do {
            let value = try await store.api.request("me/player/recently-played?limit=20")
            try Task.checkCancellation(); guard requests.accepts(ticket) else { return }
            recent = ItemPage(value, wrapper: "track").rows
        } catch is CancellationError { return } catch { if requests.accepts(ticket) { failure = error.localizedDescription } }
        guard requests.accepts(ticket), !Task.isCancelled else { return }
        do {
            let value = try await store.api.request("me/top/tracks?limit=20&time_range=short_term")
            try Task.checkCancellation(); guard requests.accepts(ticket) else { return }
            top = ItemPage(value).rows
        } catch is CancellationError { } catch { if requests.accepts(ticket) { failure = error.localizedDescription } }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore
    @State var section: LibrarySection = .playlists
    @State private var rows: [ItemRow] = []
    @State private var next: String?
    @State private var loading = false
    @State private var failure: String?
    @State private var create = false
    @State private var name = ""
    @State private var requests = RequestGate()
    var body: some View {
        List {
            Section {
                Picker("Collection", selection: $section) { ForEach(LibrarySection.allCases) { Text($0.rawValue).tag($0) } }
            }
            if loading && rows.isEmpty { ProgressView("Loading \(section.rawValue)") }
            if let failure { Text(failure).foregroundStyle(.secondary); Button("Try again") { Task { await load(reset: rows.isEmpty) } } }
            if rows.isEmpty && !loading && failure == nil { ContentUnavailableView("No \(section.rawValue.lowercased()) yet", systemImage: "square.stack", description: Text("Items saved in Spotify appear here.")) }
            ForEach(rows) { row in
                if row.item.isAudio { MusicRow(item: row.item) }
                else { NavigationLink { CollectionView(item: row.item) } label: { ItemSummary(item: row.item) } }
            }
            if next != nil { LoadMore(loading: loading) { Task { await load(reset: false) } } }
        }
        .navigationTitle("Library")
        .toolbar { if section == .playlists { Button("Create playlist", systemImage: "plus") { create = true } } }
        .alert("New playlist", isPresented: $create) { TextField("Name", text: $name); Button("Create") { store.perform { _ = try await store.api.createPlaylist(name: name); name = ""; await load(reset: true) } }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty); Button("Cancel", role: .cancel) {} }
        .task(id: section) { await load(reset: true) }
        .refreshable { await load(reset: true) }
        .scrollDismissesKeyboard(.interactively)
    }
    private func load(reset: Bool) async {
        let currentSection = section
        if loading && !reset { return }
        let ticket = requests.begin()
        loading = true; failure = nil
        defer { if requests.accepts(ticket) { loading = false; requests.finish(ticket) } }
        if reset { rows = []; next = nil }
        do {
            let page = try await store.api.library(currentSection, next: reset ? nil : next)
            try Task.checkCancellation(); guard requests.accepts(ticket), currentSection == section else { return }
            rows = reset ? page.rows : rows + page.rows; next = page.next
        } catch is CancellationError { } catch { if requests.accepts(ticket) { failure = error.localizedDescription } }
    }
}

struct ItemSummary: View {
    let item: SpotifyItem
    var body: some View {
        HStack(spacing: 12) { Artwork(url: item.image); VStack(alignment: .leading, spacing: 4) { Text(item.name).lineLimit(2); Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }.frame(minHeight: 52)
    }
}

struct SearchView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var kind = "track"
    @State private var rows: [ItemRow] = []
    @State private var next: String?
    @State private var loading = false
    @State private var failure: String?
    @State private var requests = RequestGate()
    private let kinds = ["track", "album", "artist", "playlist", "show", "episode"]
    var body: some View {
        List {
            Picker("Search in", selection: $kind) { ForEach(kinds, id: \.self) { Text($0 == "show" ? "Podcasts" : $0.capitalized + "s").tag($0) } }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ContentUnavailableView("Find your next listen", systemImage: "magnifyingglass", description: Text("Search songs, artists, albums, playlists, and podcasts.")) }
            else if let failure { Text(failure); Button("Try again") { Task { await search(reset: true) } } }
            if loading && rows.isEmpty { ProgressView("Searching Spotify") }
            ForEach(rows) { row in
                if row.item.isAudio { MusicRow(item: row.item) }
                else { NavigationLink { CollectionView(item: row.item) } label: { ItemSummary(item: row.item) } }
            }
            if !loading && !query.isEmpty && rows.isEmpty && failure == nil { Text("No results").foregroundStyle(.secondary) }
            if next != nil { LoadMore(loading: loading) { Task { await search(reset: false) } } }
        }
        .navigationTitle("Search").searchable(text: $query, prompt: "What do you want to hear?")
        .scrollDismissesKeyboard(.interactively)
        .task(id: "\(query):\(kind)") {
            requests.cancel(); rows = []; next = nil; failure = nil; loading = false
            do { try await Task.sleep(for: .milliseconds(350)); try Task.checkCancellation(); await search(reset: true) } catch { }
        }
    }
    private func search(reset: Bool) async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines); let type = kind
        guard !text.isEmpty else { loading = false; return }
        if !reset && loading { return }
        let ticket = requests.begin()
        loading = true; failure = nil
        defer { if requests.accepts(ticket) { loading = false; requests.finish(ticket) } }
        do {
            let page: ItemPage
            if let uri = RustBridge.spotifyURI(text), !uri.hasPrefix("spotify:search:") {
                let parts = uri.components(separatedBy: ":")
                guard parts.count == 3, kinds.contains(parts[1]) else { throw AppError.message("This Spotify link type is not supported on iPhone yet") }
                let value = try await store.api.request("\(parts[1])s/\(parts[2])")
                page = ItemPage(.object(["items": .array([value])]))
            }
            else if !reset, let next { page = ItemPage(try await store.api.request(next)[type == "show" ? "shows" : type + "s"]) }
            else { page = try await store.api.search(text, kind: type) }
            try Task.checkCancellation(); guard requests.accepts(ticket), text == query.trimmingCharacters(in: .whitespacesAndNewlines), type == kind else { return }
            rows = reset ? page.rows : rows + page.rows; next = page.next
        } catch is CancellationError { } catch { if requests.accepts(ticket) { failure = error.localizedDescription } }
    }
}
