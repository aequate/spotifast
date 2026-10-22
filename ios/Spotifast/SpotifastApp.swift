import SwiftUI

@main
struct SpotifastApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
                .tint(Color.accentColor)
                .preferredColorScheme(store.preferences.theme == "light" ? .light : ["dark", "black"].contains(store.preferences.theme) ? .dark : nil)
                .task { await store.bootstrap() }
                .onChange(of: scenePhase) { _, value in store.setForeground(value == .active) }
                .onChange(of: store.preferences) { _, _ in store.settingsChanged() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in Task { await ArtworkPipeline.shared.clear() } }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Group {
            if !store.initialized { ProgressView("Opening Spotifast") }
            else if store.profile == nil { NavigationStack { SignInView() } }
            else {
                TabView {
                    NavigationStack { HomeView() }.modifier(PlayerInset()).tabItem { Label("Listen", systemImage: "house") }
                    NavigationStack { SearchView() }.modifier(PlayerInset()).tabItem { Label("Search", systemImage: "magnifyingglass") }
                    NavigationStack { LibraryView() }.modifier(PlayerInset()).tabItem { Label("Library", systemImage: "square.stack") }
                    NavigationStack { SettingsView() }.modifier(PlayerInset()).tabItem { Label("Settings", systemImage: "gearshape") }
                }
            }
        }
        .background(store.preferences.theme == "black" ? Color.black : Color(uiColor: .systemBackground))
        .scrollContentBackground(store.preferences.theme == "black" ? .hidden : .automatic)
        .modifier(StoreErrorPresenter())
        .sheet(isPresented: $store.nowPlayingPresented) { NavigationStack { PlayerView() }.environmentObject(store).modifier(StoreErrorPresenter()) }
        .sheet(isPresented: Binding(get: { store.devicesPresented && !store.nowPlayingPresented }, set: { store.devicesPresented = $0 })) { NavigationStack { DevicesView() }.environmentObject(store).modifier(StoreErrorPresenter()) }
    }
}

// The inset belongs to each tab's content, so the persistent player stays
// above the system tab bar and never displaces navigation below it.
private struct PlayerInset: ViewModifier {
    @EnvironmentObject private var store: AppStore
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if store.playback.item != nil { MiniPlayer() }
        }
    }
}

struct SignInView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.tint)
                    Text("Your music.\nA lighter player.").font(.largeTitle.bold())
                    Text("Spotifast for iPhone").font(.headline)
                    Text("Sign in to browse your library and control Spotify devices. Premium is required for playback on this iPhone.").foregroundStyle(.secondary)
                }.padding(.vertical, 24)
            }
            Section("Spotify app") {
                TextField("Client ID", text: $store.preferences.clientID).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Spotify Client ID")
                Text("Create a personal app in Spotify's developer dashboard and register this redirect URI exactly:")
                Text(PKCE.redirect).font(.footnote.monospaced()).textSelection(.enabled)
                Link("Open Spotify developer dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
            }
            Section {
                Button { Task { await store.signIn(.web) } } label: { HStack { Text("Sign in with Spotify"); Spacer(); if store.busy { ProgressView() } else { Image(systemName: "arrow.right") } } }.disabled(store.busy)
            } footer: { Text("Authorization opens Apple's secure sign-in browser. Your password stays with Spotify. Grants are stored in this iPhone's Keychain.") }
        }.navigationTitle("Spotifast").scrollDismissesKeyboard(.interactively)
    }
}
