import Foundation

struct Preferences: Codable, Equatable, Sendable {
    var theme = "system"
    var bitrate = 160
    var normalisation = true
    var gapless = true
    var eqEnabled = false
    var preamp: Float = 0
    var bands = [Float](repeating: 0, count: 10)
    var balance: Float = 0
    var mono = false
    var clientID = ""
    var deviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

actor PreferencesFile {
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Spotifast", isDirectory: true)
    }
    func load() throws -> Preferences {
        let file = directory.appendingPathComponent("preferences.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Preferences() }
        let result = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file))
        guard result.bands.count == 10, [96, 160, 320].contains(result.bitrate), result.bands.allSatisfy(\.isFinite), result.preamp.isFinite, result.balance.isFinite else { throw AppError.message("Saved settings are invalid") }
        return result
    }
    func save(_ preferences: Preferences) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(preferences).write(to: directory.appendingPathComponent("preferences.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func saveSession(_ data: JSON) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(data).write(to: directory.appendingPathComponent("session.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func session(account: String) throws -> JSON? {
        let path = directory.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: path))
        return data["account"].string == account ? data : nil
    }
    func clearSession() throws {
        let path = directory.appendingPathComponent("session.json")
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}
