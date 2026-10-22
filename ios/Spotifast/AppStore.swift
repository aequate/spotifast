import Combine
import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var profile: Profile?
    @Published var preferences = Preferences()
    @Published var playback = Playback()
    @Published var local: EngineSnapshot?
    @Published var devices: [Device] = []
    @Published var queue: [QueueEntry] = []
    @Published var error: String?
    @Published var busy = false
    @Published var initialized = false
    @Published var savedSession: JSON?
    @Published var nowPlayingPresented = false
    @Published var queuePresented = false
    @Published var devicesPresented = false
    @Published var errorPresenters: [UUID] = []
    let oauth = OAuthClient()
    lazy var api = SpotifyAPI(oauth: oauth)
    private let browser = BrowserSignIn()
    private let files = PreferencesFile()
    private let rust = RustBridge.shared
    private let audio = AudioOutput()
    private let media = MediaControls()
    private var generation = 0
    private var foreground = true
    private var poll: Task<Void, Never>?
    private var preferencesSave: Task<Void, Never>?
    private var credentialsSaved = false
    private var queueRevision = 0
    private var optimisticUntil = Date.distantPast
    private var lastSession: JSON?
    private var lastEngineError: String?
    private var commandTail: Task<Void, Never>?
    private var commandTasks: [UUID: (task: Task<Void, Never>, serial: Bool)] = [:]
    private var commandGeneration = 0
    private var playbackRevision = 0
    private var settle: Task<Void, Never>?
    var localConnected: Bool { local?.connected == true }
    var localQueueEditable: Bool { playback.isLocal && local?.connected == true && local?.active == true }
    private(set) var queueEditRevision = 0

    struct QueueEntry: Identifiable {
        let id: UUID
        let uri: String
        var item: SpotifyItem?
        let manual: Bool
        init(uri: String, item: SpotifyItem? = nil, manual: Bool) { id = UUID(); self.uri = uri; self.item = item; self.manual = manual }
    }

    init() {
        rust.observe { [weak self] snapshot, credentials in
            Task { @MainActor in await self?.receive(snapshot, credentials: credentials) }
        }
        audio.onInterruption = { [weak self] in self?.pauseForAudioInterruption() }
        audio.onResume = { [weak self] in if self?.playback.isLocal == true { self?.transport("play") } }
        audio.onError = { [weak self] error in self?.error = error.localizedDescription; self?.pauseForAudioInterruption() }
        media.play = { [weak self] in self?.transport("play") }
        media.pause = { [weak self] in self?.transport("pause") }
        media.next = { [weak self] in self?.transport("next") }
        media.previous = { [weak self] in self?.transport("previous") }
        media.seek = { [weak self] value in self?.seek(value) }
    }

    func bootstrap() async {
        guard !initialized else { return }
        let epoch = generation
        defer { initialized = true }
        do {
            preferences = try await files.load()
            if preferences.clientID.isEmpty, let configured = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String, configured.count == 32 { preferences.clientID = configured }
            try await files.save(preferences)
            try await applyEQ()
            try await oauth.restore()
            let restored: Profile
            do { restored = try await Profile(api.request("me")) }
            catch { return } // First launch has no grant; the sign-in screen owns it.
            guard epoch == generation else { return }
            await oauth.verifyAccount(restored.id)
            try await api.configureCache(account: restored.id)
            let session = try await files.session(account: restored.id)
            guard epoch == generation else { return }
            profile = restored; savedSession = session
            startPolling()
        } catch { self.error = error.localizedDescription }
    }

    func signIn(_ grant: Grant) async {
        guard !busy else { return }
        let client = preferences.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard client.count == 32, client.allSatisfy(\.isHexDigit) else { error = "Enter your Spotify app's 32 character Client ID. Register spotifast-ios://oauth/callback as its redirect URI."; return }
        let epoch = generation
        busy = true; defer { if epoch == generation { busy = false } }
        do {
            if grant == .playback, profile?.premium == false { throw AppError.message("Local playback requires Spotify Premium") }
            try await browser.signIn(clientID: client, grant: grant, oauth: oauth)
            guard epoch == generation else { return }
            if grant == .web {
                let signedIn = try await Profile(api.request("me"))
                guard epoch == generation else { return }
                await oauth.verifyAccount(signedIn.id)
                try await api.configureCache(account: signedIn.id)
                let session = try await files.session(account: signedIn.id)
                guard epoch == generation else { return }
                profile = signedIn; savedSession = session
                startPolling()
            } else {
                try await oauth.clearSavedPlayback()
                guard epoch == generation else { return }
                credentialsSaved = false
                try await connectLocal(useSaved: false)
            }
        } catch is CancellationError { }
        catch { if epoch == generation { self.error = error.localizedDescription } }
    }

    func reconnect() async {
        let epoch = generation
        do { try await connectLocal(useSaved: true) }
        catch { if epoch == generation { error = error.localizedDescription } }
    }
    private func connectLocal(useSaved: Bool) async throws {
        guard let profile, profile.premium != false else { throw AppError.message("Sign in with a Spotify Premium account first") }
        let epoch = generation
        audio.allowPlayback()
        let credentials = useSaved ? try await oauth.playbackCredentials() : nil
        let token = credentials == nil || credentials == .null ? try await oauth.access(.playback) : nil
        let cacheDirectory = await api.audioCacheDirectory()
        guard epoch == generation else { return }
        credentialsSaved = false
        try await rust.send(.object([
            "op": .string("connect"), "token": token.map(JSON.string) ?? .null,
            "credentials": credentials ?? .null, "username": .string(profile.id),
            "device_id": .string(preferences.deviceID), "name": .string("Spotifast iPhone"),
            "bitrate": .number(Double(preferences.bitrate)), "normalisation": .bool(preferences.normalisation), "gapless": .bool(preferences.gapless),
            "cache_directory": cacheDirectory.map(JSON.string) ?? .null
        ]))
    }

    func signOut() async {
        generation += 1; queueRevision += 1; playbackRevision += 1; queueEditRevision += 1
        busy = true; defer { busy = false }
        browser.cancel()
        poll?.cancel(); poll = nil; invalidateCommands(); settle?.cancel(); settle = nil
        nowPlayingPresented = false; queuePresented = false; devicesPresented = false; devices = []
        error = nil; lastEngineError = nil; optimisticUntil = .distantPast
        audio.cancelAutomaticResume()
        audio.stop(); profile = nil; local = nil; playback = Playback(); queue = []; savedSession = nil; lastSession = nil; credentialsSaved = false
        media.update(playback)
        do { try await rust.send(.object(["op": .string("disconnect")])) } catch { self.error = error.localizedDescription }
        await api.invalidate()
        do { try await oauth.signOut(); try await files.clearSession() } catch { self.error = error.localizedDescription }
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active { startPolling(); rust.signal() }
        else { poll?.cancel(); poll = nil }
    }
    private func startPolling() {
        poll?.cancel()
        guard profile != nil, foreground else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshPlayback()
                do { try await Task.sleep(for: .seconds(self.playback.isLocal ? 30 : 15)) } catch { return }
            }
        }
    }
    func refreshPlayback() async {
        let epoch = generation
        let began = Date()
        do {
            let remote = try await api.playback()
            guard epoch == generation, profile != nil, began > optimisticUntil else { return }
            if let remote, remote.deviceID != preferences.deviceID {
                playback = remote; media.update(playback)
            } else if remote == nil && !localConnected { playback = Playback(); media.update(playback) }
        } catch is CancellationError { }
        catch { if epoch == generation { error = error.localizedDescription } }
    }

    private func receive(_ snapshot: EngineSnapshot, credentials: Data?) async {
        guard let account = profile?.id else { audio.stop(); return }
        guard snapshot.username.isEmpty || snapshot.username == account else { return }
        let epoch = generation
        let beganPlaying = snapshot.playing && local?.playing != true
        local = snapshot
        if let message = snapshot.error, message != lastEngineError { error = message }; lastEngineError = snapshot.error
        if snapshot.connected, snapshot.active, snapshot.uri != nil {
            var value = Playback()
            value.item = SpotifyItem(.object(["uri": snapshot.uri.map(JSON.string) ?? .null, "name": .string(snapshot.title), "type": .string(snapshot.uri?.contains(":episode:") == true ? "episode" : "track"), "duration_ms": .number(Double(snapshot.durationMs)), "artists": .array(snapshot.artists.map { .object(["name": .string($0)]) }), "images": .array(snapshot.coverUrl.map { [.object(["url": .string($0), "width": .number(300)])] } ?? [])]))
            value.playing = snapshot.playing; value.position = snapshot.positionMs; value.shuffle = snapshot.shuffle; value.repeatMode = snapshot.repeat; value.volume = Int(Double(snapshot.volume) / 65535 * 100)
            value.isLocal = true; value.deviceID = preferences.deviceID; value.deviceName = "This iPhone"
            if Date() > optimisticUntil { playback = value }
        }
        if !snapshot.connected && playback.isLocal { playback.position = playback.progress; playback.updated = Date(); playback.playing = false }
        let lostLocalDevice = snapshot.connected && !snapshot.active && playback.isLocal && Date() > optimisticUntil
        if lostLocalDevice {
            playback.position = playback.progress; playback.updated = Date(); playback.playing = false
            playback.isLocal = false; playback.deviceID = nil; playback.deviceName = "Spotify"
            queue = []; queueRevision += 1
        }
        if snapshot.audioRunning && snapshot.active {
            if beganPlaying { audio.allowPlayback() }
            do { try audio.start() } catch { self.error = error.localizedDescription; pauseForAudioInterruption() }
        } else { audio.stop() }
        media.update(playback)
        if lostLocalDevice, foreground { await refreshPlayback() }
        guard epoch == generation, local?.revision == snapshot.revision else { return }
        if playback.isLocal, Date() > optimisticUntil {
            let old = queue
            let changed = old.map(\.uri) != snapshot.queue.map(\.uri) || old.map(\.manual) != snapshot.queue.map(\.manual)
            if changed { queueRevision += 1 }
            queue = snapshot.queue.enumerated().map { index, row in
                if index < old.count, old[index].uri == row.uri, old[index].manual == row.manual { return old[index] }
                return QueueEntry(uri: row.uri, item: old.first { $0.uri == row.uri }?.item, manual: row.manual)
            }
        }
        if !credentialsSaved, let credentials {
            do { try await oauth.savePlaybackCredentials(credentials, account: account); if epoch == generation { credentialsSaved = true } } catch is CancellationError { return } catch { if epoch == generation { error = error.localizedDescription } }
        }
        guard epoch == generation, profile?.id == account else { return }
        let session: JSON = .object(["account": .string(account), "uri": snapshot.uri.map(JSON.string) ?? .null, "context": .string(snapshot.contextUri), "position_ms": .number(Double(snapshot.positionMs)), "manual": .strings(snapshot.queue.filter(\.manual).map(\.uri))])
        if snapshot.uri != nil, session != lastSession {
            do { try await files.saveSession(session); if epoch == generation { lastSession = session; savedSession = session } } catch { if epoch == generation { self.error = error.localizedDescription } }
        }
    }

    // Playback commands are serialized. A failed append is never retried: Spotify may
    // have accepted it before a network response was lost.
    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        schedule(action, serial: false)
    }
    private func performPlayback(_ action: @escaping @MainActor () async throws -> Void) {
        schedule(action, serial: true)
    }
    private func schedule(_ action: @escaping @MainActor () async throws -> Void, serial: Bool) {
        let previous = serial ? commandTail : nil
        let epoch = generation
        let commands = commandGeneration
        let id = UUID()
        let task = Task {
            defer { commandTasks[id] = nil }
            await previous?.value
            guard epoch == generation, (!serial || commands == commandGeneration), !Task.isCancelled else { return }
            do { try await action() }
            catch is CancellationError { }
            catch {
                guard epoch == generation, (!serial || commands == commandGeneration) else { return }
                self.error = error.localizedDescription
                if serial {
                    self.optimisticUntil = .distantPast; self.rust.signal()
                    await self.refreshPlayback()
                    if self.queuePresented { await self.refreshQueue() }
                }
            }
        }
        commandTasks[id] = (task, serial)
        if serial { commandTail = task }
    }
    private func invalidateCommands(includeLibrary: Bool = true) {
        commandGeneration += 1
        let cancelled = commandTasks.filter { includeLibrary || $0.value.serial }
        for (id, entry) in cancelled { entry.task.cancel(); commandTasks[id] = nil }
        commandTail = nil
    }
    @discardableResult
    private func hold() -> Int {
        playbackRevision += 1
        optimisticUntil = Date().addingTimeInterval(2)
        settle?.cancel()
        let epoch = generation; let revision = playbackRevision
        // Rust state changes are event driven. An event ignored during the
        // optimistic window may be the final event, so explicitly read again.
        settle = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, epoch == self.generation, revision == self.playbackRevision else { return }
            self.optimisticUntil = .distantPast; self.rust.signal()
            if self.foreground { await self.refreshPlayback() }
            if self.queuePresented { await self.refreshQueue() }
        }
        return revision
    }
    private func pauseForAudioInterruption() {
        guard playback.isLocal else { return }
        invalidateCommands(includeLibrary: false)
        playback.position = playback.progress; playback.updated = Date(); playback.playing = false; hold()
        media.update(playback)
        // Bypass catalogue work and release a decoder blocked on a full PCM
        // buffer now that iOS has stopped consuming audio.
        let epoch = generation
        Task {
            do { try await rust.send(.object(["op": .string("pause")])) }
            catch { if epoch == generation { self.error = error.localizedDescription } }
        }
    }
    func transport(_ command: String) {
        let before = playback; let epoch = generation; let revision = hold()
        if command == "play", before.isLocal { audio.allowPlayback() }
        if command == "pause", before.isLocal { audio.cancelAutomaticResume() }
        if command == "play" { playback.position = playback.progress; playback.updated = Date(); playback.playing = true }
        if command == "pause" { playback.position = playback.progress; playback.updated = Date(); playback.playing = false }
        if command == "next", !queue.isEmpty {
            queueRevision += 1
            let first = queue.removeFirst(); if let item = first.item { playback.item = item; playback.position = 0; playback.updated = Date() }
        }
        media.update(playback)
        performPlayback {
            do {
                if before.isLocal { try await self.rust.send(.object(["op": .string(command)])) }
                else { try await self.api.control(command == "previous" ? "previous" : command, method: ["next", "previous"].contains(command) ? "POST" : "PUT", device: before.deviceID) }
            } catch { if epoch == self.generation, revision == self.playbackRevision { self.playback = before; self.media.update(before) }; throw error }
        }
    }
    func play(_ item: SpotifyItem, context: SpotifyItem? = nil, offset: Int? = nil) {
        guard item.playable else { error = "Spotify does not make this item playable here"; return }
        let targetLocal = playback.deviceID == nil || playback.isLocal
        if targetLocal && !localConnected { error = "Connect local playback in Settings or choose an active Spotify device first"; devicesPresented = true; return }
        let before = playback
        let manual = queue.filter(\.manual).map(\.uri)
        let epoch = generation; let revision = hold()
        if targetLocal { audio.allowPlayback() }
        if item.isAudio { playback.item = item; playback.position = 0; playback.updated = Date(); playback.playing = true }
        playback.isLocal = targetLocal
        if targetLocal { playback.deviceID = preferences.deviceID; playback.deviceName = "This iPhone" }
        performPlayback {
            do {
                let collection = context ?? (item.isAudio ? nil : item)
                if targetLocal {
                    try await self.rust.send(.object(["op": .string("load"), "context": collection.map { .string($0.uri) } ?? .null, "uris": .strings(item.isAudio && context == nil ? [item.uri] : []), "offset": offset.map { .number(Double($0)) } ?? .null, "queued": .strings(manual)]))
                } else {
                    var body: [String: JSON] = collection.map { ["context_uri": .string($0.uri)] } ?? ["uris": .strings([item.uri])]
                    if let offset { body["offset"] = .object(["position": .number(Double(offset))]) }
                    try await self.api.control("play", body: .object(body), device: before.deviceID)
                }
            } catch { if epoch == self.generation, revision == self.playbackRevision { self.playback = before }; throw error }
        }
    }
    func seek(_ milliseconds: Int) {
        let target = playback
        let value = max(0, min(milliseconds, playback.item?.duration ?? 0))
        playback.position = value; playback.updated = Date(); hold()
        performPlayback {
            if target.isLocal { try await self.rust.send(.object(["op": .string("seek"), "position_ms": .number(Double(value))])) }
            else { try await self.api.control("seek?position_ms=\(value)", device: target.deviceID) }
        }
    }
    func shuffle() {
        let target = playback
        playback.shuffle.toggle(); let value = playback.shuffle; hold()
        performPlayback {
            if target.isLocal { try await self.rust.send(.object(["op": .string("shuffle"), "enabled": .bool(value)])) }
            else { try await self.api.control("shuffle?state=\(value)", device: target.deviceID) }
        }
    }
    func repeatPlayback() {
        let target = playback
        let mode = playback.repeatMode == "off" ? "context" : playback.repeatMode == "context" ? "track" : "off"
        playback.repeatMode = mode; hold()
        performPlayback {
            if target.isLocal { try await self.rust.send(.object(["op": .string("repeat"), "mode": .string(mode)])) }
            else { try await self.api.control("repeat?state=\(mode)", device: target.deviceID) }
        }
    }
    func volume(_ value: Int) {
        let target = playback; let value = max(0, min(100, value))
        playback.volume = value; hold()
        performPlayback {
            if target.isLocal { try await self.rust.send(.object(["op": .string("volume"), "value": .number((Double(value) / 100 * 65535).rounded())])) }
            else { try await self.api.control("volume?volume_percent=\(value)", device: target.deviceID) }
        }
    }
    func addToQueue(_ items: [SpotifyItem], next: Bool = false) {
        let items = items.filter { $0.isAudio && $0.playable }
        guard !items.isEmpty else { return }
        if next && !localQueueEditable { error = "Play Next is available when this iPhone is the active player"; return }
        let target = playback; let before = queue; let epoch = generation
        let added = items.map { QueueEntry(uri: $0.uri, item: $0, manual: true) }
        if next { queue.insert(contentsOf: added, at: 0) }
        else { queue.insert(contentsOf: added, at: queue.firstIndex(where: { !$0.manual }) ?? queue.endIndex) }
        hold(); queueRevision += 1
        let revision = queueRevision
        let manual = queue.filter(\.manual).map(\.uri)
        performPlayback {
            do {
                if target.isLocal { try await self.rust.send(.object(["op": .string(next ? "rewrite_queue" : "queue"), "uris": .strings(next ? manual : items.map(\.uri))])) }
                else {
                    for item in items {
                        guard epoch == self.generation, target.deviceID == self.playback.deviceID else { throw CancellationError() }
                        try await self.api.control("queue?uri=" + SpotifyAPI.escape(item.uri), method: "POST", device: target.deviceID)
                    }
                }
            } catch { if target.isLocal, epoch == self.generation, revision == self.queueRevision { self.queue = before }; throw error }
        }
    }
    func rewriteQueue(_ manual: [QueueEntry]) {
        guard localQueueEditable else { return }
        queueEditRevision += 1
        let context = queue.filter { !$0.manual }; queue = manual + context; hold(); queueRevision += 1
        performPlayback { try await self.rust.send(.object(["op": .string("rewrite_queue"), "uris": .strings(manual.map(\.uri))])) }
    }
    func skipQueue(_ index: Int) {
        guard localQueueEditable, queue.indices.contains(index) else { return }
        let item = queue[index].item; queue.removeFirst(index + 1); hold(); queueRevision += 1
        if let item { playback.item = item; playback.position = 0; playback.updated = Date() }
        performPlayback { try await self.rust.send(.object(["op": .string("skip_queue"), "index": .number(Double(index))])) }
    }
    func refreshQueue() async {
        let revision = queueRevision; let epoch = generation; let target = playback; let began = Date()
        do {
            if playback.isLocal {
                rust.signal()
                // Read metadata only for visible queue rows, at most one at a
                // time. No unbounded queue expansion or catalogue prefetch.
                for index in queue.indices.prefix(30) {
                    guard revision == queueRevision, epoch == generation, queue.indices.contains(index), !Task.isCancelled else { return }
                    if queue[index].item != nil { continue }
                    let uri = queue[index].uri
                    let parts = uri.components(separatedBy: ":")
                    guard parts.count == 3, ["track", "episode"].contains(parts[1]) else { continue }
                    let value = try await api.request("\(parts[1])s/\(parts[2])")
                    if revision == queueRevision, epoch == generation, target.deviceID == playback.deviceID, queue.indices.contains(index), queue[index].uri == uri { queue[index].item = SpotifyItem(value) }
                }
            } else {
                let items = try await api.queue()
                if revision == queueRevision, epoch == generation, target.deviceID == playback.deviceID, began > optimisticUntil { queue = items.map { QueueEntry(uri: $0.uri, item: $0, manual: false) } }
            }
        } catch is CancellationError { }
        catch { if epoch == generation { error = error.localizedDescription } }
    }
    func refreshDevices() async {
        let epoch = generation
        do { let values = try await api.devices(); if epoch == generation { devices = values } } catch { if epoch == generation { error = error.localizedDescription } }
    }
    func transfer(_ device: Device) {
        guard !device.restricted else { error = "Spotify does not allow control of this device"; return }
        let before = playback; let epoch = generation; let revision = hold()
        playback.deviceID = device.id; playback.deviceName = device.name; playback.isLocal = device.id == preferences.deviceID
        playback.position = before.progress; playback.updated = Date(); playback.playing = false
        queueRevision += 1; queue = []; devicesPresented = false
        if playback.isLocal { audio.allowPlayback() } else { audio.stop() }
        media.update(playback)
        performPlayback {
            do {
                if device.id == self.preferences.deviceID { try await self.rust.send(.object(["op": .string("transfer")])) }
                else { try await self.api.transfer(device.id) }
            } catch { if epoch == self.generation, revision == self.playbackRevision { self.playback = before; self.media.update(before) }; throw error }
        }
    }
    func settingsChanged() {
        preferencesSave?.cancel()
        let value = preferences
        preferencesSave = Task {
            do {
                try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation()
                try await files.save(value); try await applyEQ()
            } catch is CancellationError { } catch { error = error.localizedDescription }
        }
    }
    func applyEQ() async throws {
        try await rust.send(.object(["op": .string("eq"), "enabled": .bool(preferences.eqEnabled), "preamp": .number(Double(preferences.preamp)), "bands": .array(preferences.bands.map { .number(Double($0)) }), "balance": .number(Double(preferences.balance)), "mono": .bool(preferences.mono)]))
    }
    func restoreSession() {
        guard localConnected, let session = savedSession, let uri = session["uri"].string, session["account"].string == profile?.id else { return }
        playback.isLocal = true
        playback.deviceID = preferences.deviceID; playback.deviceName = "This iPhone"; playback.playing = false; hold()
        audio.allowPlayback()
        performPlayback { try await self.rust.send(.object(["op": .string("restore"), "context": session["context"], "uri": .string(uri), "position_ms": session["position_ms"], "uris": session["manual"]])) }
    }
    func loadLyrics(_ uri: String) async throws {
        try await rust.send(.object(["op": .string("lyrics"), "uri": .string(uri)]))
    }
    func clearCache() async {
        guard let account = profile?.id else { return }
        let epoch = generation
        do {
            // Disconnect before deleting files used by the streaming session.
            audio.stop()
            try await rust.send(.object(["op": .string("disconnect")]))
            await api.invalidate()
            guard epoch == generation else { return }
            try await api.configureCache(account: account)
            await ArtworkPipeline.shared.clear()
        } catch { if epoch == generation { error = error.localizedDescription } }
    }
}
