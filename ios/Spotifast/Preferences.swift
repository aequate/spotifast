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
    init() {}
    private enum CodingKeys: String, CodingKey { case theme, bitrate, normalisation, gapless, eqEnabled, preamp, bands, balance, mono, clientID, deviceID }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? theme
        bitrate = try values.decodeIfPresent(Int.self, forKey: .bitrate) ?? bitrate
        normalisation = try values.decodeIfPresent(Bool.self, forKey: .normalisation) ?? normalisation
        gapless = try values.decodeIfPresent(Bool.self, forKey: .gapless) ?? gapless
        eqEnabled = try values.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? eqEnabled
        preamp = try values.decodeIfPresent(Float.self, forKey: .preamp) ?? preamp
        bands = try values.decodeIfPresent([Float].self, forKey: .bands) ?? bands
        balance = try values.decodeIfPresent(Float.self, forKey: .balance) ?? balance
        mono = try values.decodeIfPresent(Bool.self, forKey: .mono) ?? mono
        clientID = try values.decodeIfPresent(String.self, forKey: .clientID) ?? clientID
        deviceID = try values.decodeIfPresent(String.self, forKey: .deviceID) ?? deviceID
        try validate()
    }
    func validate() throws {
        guard bands.count == 10, [96, 160, 320].contains(bitrate), bands.allSatisfy({ $0.isFinite && (-12...12).contains($0) }),
              preamp.isFinite, (-12...12).contains(preamp), balance.isFinite, (-1...1).contains(balance),
              ["system", "light", "dark", "black"].contains(theme), deviceID.utf8.count == 32,
              deviceID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw AppError.message("Saved settings are invalid")
        }
    }
}

actor PreferencesFile {
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Spotifast", isDirectory: true)
    }
    func load() throws -> Preferences {
        let file = directory.appendingPathComponent("preferences.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Preferences() }
        let result = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file))
        return result
    }
    func save(_ preferences: Preferences) throws {
        try preferences.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(preferences).write(to: directory.appendingPathComponent("preferences.json"), options: CacheStore.writeOptions)
    }
    func saveSession(_ data: JSON) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(data).write(to: directory.appendingPathComponent("session.json"), options: CacheStore.writeOptions)
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
