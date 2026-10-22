// Kept independent of AVAudioSession so interruption ordering can be tested
// without a route or a live Spotify session.
struct AudioInterruptionGate {
    private(set) var interrupted = false
    private(set) var suspended = false
    private var resumePending = false
    var canStart: Bool { !interrupted && !suspended }
    mutating func begin(wasRunning: Bool) {
        if !interrupted { resumePending = wasRunning }
        interrupted = true; suspended = true
    }
    mutating func end(shouldResume: Bool) -> Bool {
        let resume = interrupted && resumePending && shouldResume
        interrupted = false; resumePending = false; suspended = true
        // Remain suspended until a deliberate play/resume request arrives.
        return resume
    }
    mutating func playRequested() {
        suspended = false
        if interrupted { resumePending = true }
    }
    mutating func cancelResume() { resumePending = false; suspended = true }
    mutating func pauseRequested() { resumePending = false }
}
