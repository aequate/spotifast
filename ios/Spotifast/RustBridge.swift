import Foundation

private let rustNotification: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
    guard let context else { return }
    Unmanaged<RustBridge>.fromOpaque(context).takeUnretainedValue().signal()
}

// This single process-lifetime owner keeps the C pointer alive for the native
// render callback. Commands and JSON work run on a dedicated serial queue.
final class RustBridge: @unchecked Sendable {
    static let shared = RustBridge()
    static func platformInfo() -> JSON {
        guard let pointer = sf_platform_info() else { return .null }
        defer { sf_string_free(pointer) }
        return (try? JSONDecoder().decode(JSON.self, from: Data(bytes: pointer, count: strlen(pointer)))) ?? .null
    }
    static func spotifyURI(_ text: String) -> String? {
        guard let result = text.withCString({ sf_parse_link($0) }) else { return nil }
        defer { sf_string_free(result) }
        return String(cString: result)
    }
    private let queue = DispatchQueue(label: "spotifast.rust.control", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = false
    private var listener: (@Sendable (EngineSnapshot, Data?) -> Void)?
    private(set) var handle: OpaquePointer?
    private init() { handle = sf_create(rustNotification, Unmanaged.passUnretained(self).toOpaque()) }
    func observe(_ listener: @escaping @Sendable (EngineSnapshot, Data?) -> Void) {
        queue.async { self.listener = listener; self.signal() }
    }
    func signal() {
        lock.lock(); let shouldSchedule = !pending; pending = true; lock.unlock()
        guard shouldSchedule else { return }
        queue.async {
            self.lock.lock(); self.pending = false; self.lock.unlock()
            guard let handle = self.handle, let pointer = sf_snapshot(handle) else { return }
            let data = Data(bytes: pointer, count: strlen(pointer)); sf_string_free(pointer)
            guard let snapshot = try? JSONDecoder().decode(EngineSnapshot.self, from: data) else { return }
            var credentials: Data?
            if snapshot.connected, let value = sf_credentials(handle) {
                credentials = Data(bytes: value, count: strlen(value)); sf_string_free(value)
            }
            self.listener?(snapshot, credentials)
        }
    }
    func send(_ command: JSON) async throws {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(command)
        guard let text = String(data: data, encoding: .utf8) else { throw AppError.message("Could not encode a playback command") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let handle = self.handle else { continuation.resume(throwing: AppError.message("The Rust playback engine could not start")); return }
                if text.withCString({ sf_command(handle, $0) }) { continuation.resume() }
                else {
                    var message = "Playback could not accept the command. Reconnect in Settings."
                    if let value = sf_snapshot(handle) {
                        defer { sf_string_free(value) }
                        if let snapshot = try? JSONDecoder().decode(EngineSnapshot.self, from: Data(bytes: value, count: strlen(value))), let detail = snapshot.error { message = detail }
                    }
                    continuation.resume(throwing: AppError.message(message))
                }
                self.signal()
            }
        }
    }
}
