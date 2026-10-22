import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirmSignOut = false
    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("Signed in", value: store.profile?.name ?? "")
                LabeledContent("Plan", value: store.profile?.premium == true ? "Premium" : store.profile?.premium == false ? "Free" : "Not reported by Spotify")
                Text("Library and playback use separate approvals for the same Spotify account.").font(.footnote).foregroundStyle(.secondary)
                Button("Sign out", role: .destructive) { confirmSignOut = true }
            }
            Section("Playback on this iPhone") {
                LabeledContent("Status", value: store.local?.connecting == true ? "Connecting" : store.localConnected ? "Connected" : "Disconnected")
                if let error = store.local?.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                Button("Authorize playback with Spotify") { Task { await store.signIn(.playback) } }.disabled(store.busy || store.profile?.premium == false)
                Button("Reconnect") { Task { await store.reconnect() } }.disabled(store.busy || store.local?.connecting == true)
                if store.localConnected, store.savedSession != nil { Button("Restore last track and queue (paused)") { store.restoreSession() } }
                Picker("Audio quality", selection: $store.preferences.bitrate) { Text("96 kbps").tag(96); Text("160 kbps").tag(160); Text("320 kbps").tag(320) }
                Toggle("Normalize volume", isOn: $store.preferences.normalisation)
                Toggle("Gapless playback", isOn: $store.preferences.gapless)
                Text("Audio quality, normalization and gapless changes apply when you reconnect. Playback uses Spotify audio through librespot. Reconnecting interrupts local playback.").font(.footnote).foregroundStyle(.secondary)
                NavigationLink { EqualizerView() } label: { Label("Equalizer and stereo", systemImage: "slider.vertical.3") }
            }
            Section("Appearance") {
                Picker("Theme", selection: $store.preferences.theme) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark"); Text("Black").tag("black") }
            }
            Section("Spotify app") {
                Text(store.preferences.clientID).font(.footnote.monospaced()).textSelection(.enabled)
                Text("Sign out before changing the Client ID. Spotify Development Mode can restrict catalogue and playlist access.").font(.footnote).foregroundStyle(.secondary)
                Link("Spotify app dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
            }
            Section("Storage") {
                Button("Clear artwork from memory") { Task { await ArtworkPipeline.shared.clear() } }
                Button("Clear disk cache and disconnect playback") { Task { await store.clearCache() } }
                Text("Artwork memory budget: 12 MiB. Audio handoff: 128 KiB. Spotify audio cache: 128 MiB on disk. Library and catalogue cache: 8 MiB, refreshed after five minutes or when you pull to refresh. Clearing disk caches disconnects playback; tap Reconnect afterwards. Cached audio still needs Spotify authorization and is not an offline download.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Spotifast iOS", value: "0.1.0")
                Link("Original Spotifast", destination: URL(string: "https://github.com/crmne/spotifast")!)
                Text("A native music player built from the open source Spotifast project. Your music and account stay with Spotify.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
        .confirmationDialog("Sign out and remove this account's saved authorizations and queue?", isPresented: $confirmSignOut, titleVisibility: .visible) { Button("Sign out", role: .destructive) { Task { await store.signOut() } } }
    }
}

struct EqualizerView: View {
    @EnvironmentObject private var store: AppStore
    @State private var catalogue = JSON.null
    @State private var selectedPreset = "Custom"
    private var frequencies: [JSON] { catalogue["frequencies"].array }
    var body: some View {
        Form {
            Section {
                Toggle("Equalizer", isOn: $store.preferences.eqEnabled)
                Text("Applies to audio playing on this iPhone, including AirPlay and Bluetooth output. Other Spotify Connect devices apply their own sound settings.").font(.footnote).foregroundStyle(.secondary)
                Picker("Preset", selection: $selectedPreset) {
                    Text("Custom").tag("Custom")
                    ForEach(catalogue["presets"].array.compactMap { $0["name"].string }, id: \.self) { Text($0).tag($0) }
                }.onChange(of: selectedPreset) { _, value in
                    if let preset = catalogue["presets"].array.first(where: { $0["name"].string == value }) {
                        store.preferences.bands = preset["bands"].array.map { if case .number(let gain) = $0 { return Float(gain) }; return 0 }
                        store.preferences.eqEnabled = true
                    }
                }
            }
            Section("Tone") {
                gainSlider("Preamp", value: $store.preferences.preamp)
                ForEach(0..<min(10, frequencies.count), id: \.self) { index in
                    gainSlider(frequency(frequencies[index].int ?? 0), value: $store.preferences.bands[index])
                }
            }.disabled(!store.preferences.eqEnabled)
            Section("Stereo") {
                VStack(alignment: .leading) { Text("Balance"); Slider(value: $store.preferences.balance, in: -1...1, step: 0.05) { Text("Stereo balance") }; HStack { Text("Left"); Spacer(); Text("Right") }.font(.caption).foregroundStyle(.secondary) }
                Toggle("Mono audio", isOn: $store.preferences.mono)
                Button("Reset sound settings") { store.preferences.preamp = 0; store.preferences.bands = Array(repeating: 0, count: 10); store.preferences.balance = 0; store.preferences.mono = false; selectedPreset = "Flat" }
            }
        }.navigationTitle("Equalizer")
        .task {
            guard let value = sf_eq_presets() else { return }
            defer { sf_string_free(value) }
            catalogue = (try? JSONDecoder().decode(JSON.self, from: Data(bytes: value, count: strlen(value)))) ?? .null
        }
    }
    private func gainSlider(_ title: String, value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(String(format: "%+.1f dB", value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Slider(value: value, in: -12...12, step: 0.5) { Text(title) }.accessibilityValue(String(format: "%.1f decibels", value.wrappedValue))
        }.padding(.vertical, 4)
    }
    private func frequency(_ value: Int) -> String { value >= 1000 ? String(format: "%.0f kHz", Double(value) / 1000) : "\(value) Hz" }
}

struct LyricsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var failure: String?
    var body: some View {
        Group {
            if !store.localConnected { ContentUnavailableView("Connect playback first", systemImage: "quote.bubble", description: Text("Spotify lyrics require this iPhone's librespot session.")) }
            else if let failure { ContentUnavailableView("Lyrics unavailable", systemImage: "quote.bubble", description: Text(failure)) }
            else if store.local?.lyricsUri != store.playback.item?.uri { ProgressView("Asking Spotify for lyrics") }
            else if let lyrics = store.local?.lyrics, !lyrics["lyrics"]["lines"].array.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(Array(lyrics["lyrics"]["lines"].array.enumerated()), id: \.offset) { _, line in
                            Text(line["words"].string ?? "").font(.title2.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("Lyrics from \(lyrics["lyrics"]["provider"].string ?? "Spotify")").font(.footnote).foregroundStyle(.secondary)
                    }.padding(24)
                }
            } else { ContentUnavailableView("Lyrics unavailable", systemImage: "quote.bubble", description: Text("Spotify did not provide lyrics for this track, or the request failed.")) }
        }.navigationTitle("Lyrics")
        .task(id: store.playback.item?.uri) {
            failure = nil
            if store.localConnected, let uri = store.playback.item?.uri {
                do { try await store.loadLyrics(uri) } catch is CancellationError { } catch { failure = error.localizedDescription }
            } else { failure = "Choose a song to view its lyrics." }
        }
    }
}
