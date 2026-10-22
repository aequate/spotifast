import AVKit
import MediaPlayer
import SwiftUI

struct MiniPlayer: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        MiniPlayerContent(item: store.playback.item, deviceName: store.playback.deviceName, playing: store.playback.playing,
                          open: { store.nowPlayingPresented = true },
                          toggle: { store.transport(store.playback.playing ? "pause" : "play") }, next: { store.transport("next") })
    }
}

struct MiniPlayerContent: View {
    let item: SpotifyItem?
    let deviceName: String
    let playing: Bool
    let open: () -> Void
    let toggle: () -> Void
    let next: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Button(action: open) {
                HStack(spacing: 12) {
                    Artwork(url: item?.image, size: 40)
                    VStack(alignment: .leading, spacing: 3) { Text(item?.name ?? "").font(.subheadline.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? 2 : 1); Text(deviceName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 0)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Now playing: \(item?.name ?? "Nothing playing"), \(deviceName)").accessibilityHint("Opens the full player")
            HStack(spacing: 8) {
                Button(action: toggle) { Image(systemName: playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 48) }.accessibilityLabel(playing ? "Pause" : "Play")
                Button(action: next) { Image(systemName: "forward.end.fill").frame(width: 44, height: 48) }.accessibilityLabel("Next track")
            }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }.padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial)
    }
}

// Keep all five actions available when a narrow sheet cannot fit them in one
// row. Only icons cap their visual scale; text and VoiceOver labels still scale.
struct PlayerTransportControls: View {
    let playing: Bool
    let shuffle: Bool
    let repeatMode: String
    let action: (String) -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                shuffleButton
                Spacer(minLength: 8)
                previousButton
                Spacer(minLength: 8)
                playButton
                Spacer(minLength: 8)
                nextButton
                Spacer(minLength: 8)
                repeatButton
            }
            VStack(spacing: 12) {
                HStack(spacing: 16) { previousButton; playButton; nextButton }
                HStack(spacing: 32) { shuffleButton; repeatButton }
            }.frame(maxWidth: .infinity)
        }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
    private var shuffleButton: some View {
        Button { action("shuffle") } label: { Image(systemName: "shuffle").foregroundStyle(shuffle ? Color.accentColor : .secondary).frame(width: 44, height: 48) }
            .accessibilityLabel("Shuffle").accessibilityValue(shuffle ? "On" : "Off").accessibilityIdentifier("player.shuffle")
    }
    private var previousButton: some View {
        Button { action("previous") } label: { Image(systemName: "backward.end.fill").font(.title).frame(width: 48, height: 52) }
            .accessibilityLabel("Previous track").accessibilityIdentifier("player.previous")
    }
    private var playButton: some View {
        Button { action(playing ? "pause" : "play") } label: { Image(systemName: playing ? "pause.fill" : "play.fill").font(.title).frame(width: 72, height: 72).background(.tint, in: Circle()).foregroundStyle(Color(uiColor: .systemBackground)) }
            .accessibilityLabel(playing ? "Pause" : "Play").accessibilityIdentifier("player.playPause")
    }
    private var nextButton: some View {
        Button { action("next") } label: { Image(systemName: "forward.end.fill").font(.title).frame(width: 48, height: 52) }
            .accessibilityLabel("Next track").accessibilityIdentifier("player.next")
    }
    private var repeatButton: some View {
        Button { action("repeat") } label: { Image(systemName: repeatMode == "track" ? "repeat.1" : "repeat").foregroundStyle(repeatMode == "off" ? .secondary : Color.accentColor).frame(width: 44, height: 48) }
            .accessibilityLabel("Repeat").accessibilityValue(repeatMode).accessibilityIdentifier("player.repeat")
    }
}

struct PlayerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var seeking: Double?
    @State private var volume = 100.0
    @State private var adjustingVolume = false
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Artwork(url: store.playback.item?.image, size: max(160, min(geometry.size.width - 48, min(geometry.size.height * 0.44, 390))))
                        .frame(maxWidth: .infinity).padding(.top, 16)
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.playback.item?.name ?? "Nothing playing").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                            Text(store.playback.item?.subtitle ?? "Choose something from your library").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let item = store.playback.item { ItemMenu(item: item) }
                    }
                    TimelineView(.periodic(from: Date(), by: store.playback.playing ? 1 : 3600)) { _ in
                        VStack(spacing: 4) {
                            Slider(value: Binding(get: { seeking ?? Double(store.playback.progress) }, set: { seeking = $0 }), in: 0...Double(max(1, store.playback.item?.duration ?? 1))) { Text("Playback position") } onEditingChanged: { editing in if !editing, let seeking { store.seek(Int(seeking)); self.seeking = nil } }
                                .accessibilityValue(timestamp(store.playback.progress))
                                .accessibilityAdjustableAction { direction in
                                    if direction == .increment { store.seek(store.playback.progress + 10_000) }
                                    else if direction == .decrement { store.seek(store.playback.progress - 10_000) }
                                }
                            HStack { Text(timestamp(Int(seeking ?? Double(store.playback.progress)))); Spacer(); Text(timestamp(store.playback.item?.duration ?? 0)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    PlayerTransportControls(playing: store.playback.playing, shuffle: store.playback.shuffle, repeatMode: store.playback.repeatMode) { action in
                        if action == "shuffle" { store.shuffle() }
                        else if action == "repeat" { store.repeatPlayback() }
                        else { store.transport(action) }
                    }
                    if store.playback.isLocal {
                        HStack { Image(systemName: "speaker.fill"); Slider(value: $volume, in: 0...100) { Text("Player volume") } onEditingChanged: { adjustingVolume = $0; if !$0 { store.volume(Int(volume)) } }; Image(systemName: "speaker.wave.3.fill") }.foregroundStyle(.secondary)
                        Text("Use your iPhone's volume buttons for output volume.").font(.caption).foregroundStyle(.secondary)
                    }
                    let routing = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                    routing {
                        Button { store.devicesPresented = true } label: { Label(store.playback.deviceName, systemImage: store.playback.isLocal ? "iphone" : "hifispeaker").font(.subheadline).lineLimit(3).frame(minHeight: 44) }
                        HStack {
                            Spacer(minLength: 0)
                            if store.playback.isLocal { RoutePicker().frame(width: 44, height: 44).accessibilityLabel("AirPlay and audio routes") }
                            Button { store.queuePresented = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }.accessibilityLabel("Queue")
                        }
                    }
                    NavigationLink { EqualizerView() } label: { Label("Equalizer", systemImage: "slider.vertical.3").frame(minHeight: 44) }
                    NavigationLink { LyricsView() } label: { Label("Lyrics", systemImage: "quote.bubble").frame(minHeight: 44) }
                    NavigationLink { JamView() } label: { Label("Jam invites", systemImage: "qrcode").frame(minHeight: 44) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .navigationTitle("Now playing").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "chevron.down") { dismiss() } } }
        .onAppear { volume = Double(store.playback.volume) }
        .onChange(of: store.playback.volume) { _, value in if !adjustingVolume { volume = Double(value) } }
        .onChange(of: volume) { _, value in if !adjustingVolume && Int(value) != store.playback.volume { store.volume(Int(value)) } }
        .onChange(of: store.playback.item?.uri) { _, _ in seeking = nil }
        .sheet(isPresented: $store.queuePresented) { NavigationStack { QueueView() }.environmentObject(store).modifier(StoreErrorPresenter()) }
        .sheet(isPresented: $store.devicesPresented) { NavigationStack { DevicesView() }.environmentObject(store).modifier(StoreErrorPresenter()) }
    }
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let view = AVRoutePickerView(); view.prioritizesVideoDevices = false; return view }
    func updateUIView(_ view: AVRoutePickerView, context: Context) { }
}

struct DevicesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if store.localConnected {
                Section("On this phone") {
                    Button { store.transfer(Device(id: store.preferences.deviceID, name: "This iPhone", restricted: false, active: store.playback.isLocal, supportsVolume: true)) } label: { Label("This iPhone", systemImage: "iphone") }
                    RoutePicker().frame(height: 44).accessibilityLabel("Choose AirPlay or Bluetooth output")
                }
            } else { Section { Text("Set up playback in Settings to listen on this iPhone.").foregroundStyle(.secondary) } }
            Section("Spotify Connect") {
                ForEach(store.devices.filter { $0.id != store.preferences.deviceID }) { device in
                    Button { store.transfer(device) } label: {
                        HStack { Label(device.name, systemImage: "hifispeaker"); Spacer(); if device.active { Image(systemName: "checkmark") }; if device.restricted { Text("Restricted").font(.caption).foregroundStyle(.secondary) } }
                    }.disabled(device.restricted)
                }
                if store.devices.isEmpty { Text("No devices found. Open Spotify on another device, then refresh.").foregroundStyle(.secondary) }
                Button("Refresh devices") { Task { await store.refreshDevices() } }
            }
            Section { Text("Connect lists devices already signed in to Spotify. Restricted Sonos devices and signing in new receivers are not supported in this port.").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("Listen on").toolbar { Button("Done") { dismiss() } }.task { await store.refreshDevices() }.refreshable { await store.refreshDevices() }
    }
}

struct QueueView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if store.queue.isEmpty { ContentUnavailableView("The queue is empty", systemImage: "text.line.first.and.arrowtriangle.forward", description: Text("Add a song using its actions menu.")) }
            if store.playback.isLocal {
                Section("Playing next") {
                    ForEach(store.queue.filter(\.manual)) { row in queueRow(row) }
                        .onDelete { offsets in var rows = store.queue.filter(\.manual); rows.remove(atOffsets: offsets); store.rewriteQueue(rows) }
                        .onMove { source, destination in var rows = store.queue.filter(\.manual); rows.move(fromOffsets: source, toOffset: destination); store.rewriteQueue(rows) }
                        .deleteDisabled(!store.localQueueEditable).moveDisabled(!store.localQueueEditable)
                    if store.queue.contains(where: \.manual) { Button("Clear queued songs", role: .destructive) { store.rewriteQueue([]) }.disabled(!store.localQueueEditable) }
                }
            }
            Section(store.playback.isLocal ? "Next up" : "Upcoming on Spotify") {
                ForEach(store.queue.filter { !store.playback.isLocal || !$0.manual }) { row in queueRow(row) }
            }
        }.navigationTitle("Queue")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }; if store.localQueueEditable { ToolbarItem(placement: .primaryAction) { EditButton() } } }
        .task(id: store.playback.isLocal ? store.queue.map(\.uri) : ["remote", store.playback.deviceID ?? ""]) { await store.refreshQueue() }.refreshable { await store.refreshQueue() }
    }
    private func queueRow(_ row: AppStore.QueueEntry) -> some View {
        Button {
            if let index = store.queue.firstIndex(where: { $0.id == row.id }) { store.skipQueue(index) }
        } label: {
            HStack(spacing: 12) { Artwork(url: row.item?.image, size: 40); VStack(alignment: .leading, spacing: 4) { Text(row.item?.name ?? "Spotify item"); Text(row.item?.subtitle ?? row.uri).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }.frame(minHeight: 48)
        }.buttonStyle(.plain).disabled(!store.localQueueEditable)
    }
}
