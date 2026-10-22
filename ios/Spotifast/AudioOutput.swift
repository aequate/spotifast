import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class AudioOutput {
    private var engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var observers: [NSObjectProtocol] = []
    var onInterruption: (() -> Void)?
    var onResume: (() -> Void)?
    var onError: ((Error) -> Void)?
    private var interruption = AudioInterruptionGate()
    private var intendedRunning = false
    private var sessionActive = false
    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor in
                guard let self else { return }
                if type == .began {
                    self.interruption.begin(wasRunning: self.intendedRunning)
                    self.onInterruption?(); self.stop()
                } else if type == .ended, self.interruption.end(shouldResume: options.contains(.shouldResume)) { self.onResume?() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            Task { @MainActor in
                guard let self else { return }
                if reason == .oldDeviceUnavailable {
                    self.interruption.cancelResume(); self.onInterruption?(); self.stop()
                } else if reason == .newDeviceAvailable, self.intendedRunning { self.rebuild() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        })
    }
    private func configure() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
        try session.setPreferredSampleRate(44_100)
        try session.setPreferredIOBufferDuration(0.0232)
        try session.setActive(true)
        sessionActive = true
        guard source == nil else { return }
        guard let handle = RustBridge.shared.handle else { throw AppError.message("Playback engine is unavailable") }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        // Capture only the stable C pointer. The audio callback cannot allocate,
        // lock, call Swift actors, perform I/O, or access observable UI state.
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count == 2, let left = buffers[0].mData, let right = buffers[1].mData else { return kAudio_ParamError }
            sf_render(handle, left.assumingMemoryBound(to: Float.self), right.assumingMemoryBound(to: Float.self), Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
    }
    func start() throws {
        guard interruption.canStart else { return }
        intendedRunning = true
        if engine.isRunning { return }
        do { try configure(); engine.prepare(); try engine.start() }
        catch { interruption.cancelResume(); stop(); throw error }
    }
    func allowPlayback() { interruption.playRequested() }
    func cancelAutomaticResume() { interruption.pauseRequested() }
    func stop() {
        intendedRunning = false
        if engine.isRunning { engine.stop() }
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }
    private func rebuild() {
        let restart = intendedRunning
        engine.stop()
        if let source { engine.detach(source) }; source = nil
        // Media-services reset invalidates the audio objects themselves.
        // Construct a fresh engine rather than reconnecting invalid nodes.
        engine = AVAudioEngine(); sessionActive = false
        if restart { do { try start() } catch { onError?(error) } }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

@MainActor
final class MediaControls {
    private var targets: [(MPRemoteCommand, Any)] = []
    var play: (() -> Void)?
    var pause: (() -> Void)?
    var next: (() -> Void)?
    var previous: (() -> Void)?
    var seek: ((Int) -> Void)?
    init() {
        let center = MPRemoteCommandCenter.shared()
        bind(center.playCommand) { [weak self] _ in self?.play?() }
        bind(center.pauseCommand) { [weak self] _ in self?.pause?() }
        bind(center.togglePlayPauseCommand) { [weak self] _ in
            let rate = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0
            if rate > 0 { self?.pause?() } else { self?.play?() }
        }
        bind(center.nextTrackCommand) { [weak self] _ in self?.next?() }
        bind(center.previousTrackCommand) { [weak self] _ in self?.previous?() }
        bind(center.changePlaybackPositionCommand) { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek?(Int(event.positionTime * 1000)) }
        }
    }
    private func bind(_ command: MPRemoteCommand, action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
        let target = command.addTarget { event in Task { @MainActor in action(event) }; return .success }
        targets.append((command, target))
    }
    func update(_ state: Playback) {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand] { command.isEnabled = state.isLocal && state.item != nil }
        guard state.isLocal, let item = state.item else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: item.name, MPMediaItemPropertyArtist: item.subtitle, MPMediaItemPropertyAlbumTitle: "Spotifast", MPMediaItemPropertyPlaybackDuration: Double(item.duration) / 1000, MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(state.progress) / 1000, MPNowPlayingInfoPropertyPlaybackRate: state.playing ? 1.0 : 0.0]
    }
    deinit { targets.forEach { $0.0.removeTarget($0.1) } }
}
