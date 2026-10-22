import SwiftUI

struct MusicRow: View {
    @EnvironmentObject private var store: AppStore
    let item: SpotifyItem
    var action: (() -> Void)?
    var body: some View {
        HStack(spacing: 12) {
            Button { if let action { action() } else { store.play(item) } } label: {
                HStack(spacing: 12) {
                    Artwork(url: item.image)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.body.weight(store.playback.item?.uri == item.uri ? .semibold : .regular)).foregroundStyle(store.playback.item?.uri == item.uri ? Color.accentColor : .primary).lineLimit(2)
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !item.playable { Image(systemName: "nosign").foregroundStyle(.secondary).accessibilityLabel("Unavailable") }
                }.frame(minHeight: 52).contentShape(Rectangle())
            }.buttonStyle(.plain)
            ItemMenu(item: item).frame(minWidth: 44, minHeight: 44)
        }
    }
}

struct ItemMenu: View {
    @EnvironmentObject private var store: AppStore
    let item: SpotifyItem
    @State private var saved: Bool?
    @State private var showPlaylist = false
    var body: some View {
        Menu {
            if item.isAudio {
                Button("Add to queue", systemImage: "text.badge.plus") { store.addToQueue([item]) }.disabled(!item.playable)
                if store.localQueueEditable { Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") { store.addToQueue([item], next: true) }.disabled(!item.playable) }
                Button("Add to playlist", systemImage: "plus.rectangle.on.rectangle") { showPlaylist = true }
            }
            Button(saved == true ? "Remove from library" : "Save to library", systemImage: saved == true ? "checkmark.circle" : "plus.circle") {
                store.perform { let current = try await store.api.membership(item.uri); try await store.api.save(item.uri, saved: !current); saved = !current }
            }
            ShareLink(item: URL(string: "https://open.spotify.com/\(item.kind)/\(item.resourceID)")!) { Label("Share", systemImage: "square.and.arrow.up") }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()).dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
        .accessibilityLabel("Actions for \(item.name)")
        .sheet(isPresented: $showPlaylist) { NavigationStack { PlaylistPicker(item: item) }.environmentObject(store).modifier(StoreErrorPresenter()) }
    }
}

struct FailureView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load this", systemImage: "wifi.exclamationmark")
        } description: { Text(message) } actions: { Button("Try again", action: retry).buttonStyle(.bordered) }
    }
}

struct LoadMore: View {
    let loading: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { HStack { Spacer(); if loading { ProgressView() } else { Text("Load more") }; Spacer() }.frame(minHeight: 44) }.disabled(loading)
    }
}

func timestamp(_ milliseconds: Int) -> String {
    let seconds = max(0, milliseconds / 1000)
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

// The visible presentation owns errors. Presenting an alert from the root
// behind another sheet can otherwise leave a failed action with no feedback.
struct StoreErrorPresenter: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            .onAppear { if !store.errorPresenters.contains(id) { store.errorPresenters.append(id) } }
            .onDisappear { store.errorPresenters.removeAll { $0 == id } }
            .alert("Spotifast", isPresented: Binding(get: { store.error != nil && store.errorPresenters.last == id }, set: { if !$0 && store.errorPresenters.last == id { store.error = nil } })) {
                Button("OK", role: .cancel) { store.error = nil }
            } message: { Text(store.error ?? "") }
    }
}
