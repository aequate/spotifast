import Foundation

struct CacheScope: Equatable, Sendable {
    let id: UUID
    let directory: URL
    var audioDirectory: URL { directory.appendingPathComponent("audio", isDirectory: true) }
}

// The caches directory is disposable, account scoped and excluded from backups.
// Disk work happens on this actor, never on the UI or audio rendering threads.
actor CacheStore {
    static let shared = CacheStore()
    static let metadataBudget = 8 * 1024 * 1024
    static let entryLimit = 1024 * 1024
    private let root: URL
    private let budget: Int
    private var active: CacheScope?
    private struct Entry: Codable { let key: String; let expires: Date; let value: JSON }

    init(root: URL? = nil, budget: Int = CacheStore.metadataBudget) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Spotifast", isDirectory: true)
        self.budget = max(0, budget)
    }

    func open(account: String) throws -> CacheScope {
        guard !account.isEmpty, account.utf8.count <= 128 else { throw AppError.message("Invalid account cache identifier") }
        let key = Data(account.utf8).base64URL
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try create(directory.appendingPathComponent("metadata", isDirectory: true))
        try create(directory.appendingPathComponent("audio", isDirectory: true))
        let scope = CacheScope(id: UUID(), directory: directory)
        active = scope
        return scope
    }

    func read(_ key: String, scope: CacheScope, now: Date = Date()) -> JSON? {
        guard active == scope else { return nil }
        let path = file(key, scope: scope)
        guard let values = try? path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= Self.entryLimit,
              let data = try? Data(contentsOf: path), let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.key == key, entry.expires > now else { try? FileManager.default.removeItem(at: path); return nil }
        // Modification time serves as the LRU marker; reads have no timer.
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path.path)
        return entry.value
    }

    func write(_ value: JSON, key: String, ttl: TimeInterval, scope: CacheScope, now: Date = Date()) throws {
        guard active == scope, ttl > 0 else { return }
        let data = try JSONEncoder().encode(Entry(key: key, expires: now.addingTimeInterval(ttl), value: value))
        guard data.count <= min(Self.entryLimit, budget) else { return }
        let directory = scope.directory.appendingPathComponent("metadata", isDirectory: true)
        try create(directory)
        try data.write(to: file(key, scope: scope), options: Self.writeOptions)
        try prune(directory)
    }

    func invalidateMetadata(scope: CacheScope) throws {
        guard active == scope else { return }
        let directory = scope.directory.appendingPathComponent("metadata", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func close(clear: Bool) throws {
        let previous = active; active = nil
        if clear, let previous, FileManager.default.fileExists(atPath: previous.directory.path) {
            try FileManager.default.removeItem(at: previous.directory)
        }
    }

    private func file(_ key: String, scope: CacheScope) -> URL {
        // The envelope also checks the full key, so a hash collision is a miss.
        let hash = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return scope.directory.appendingPathComponent("metadata", isDirectory: true).appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    private func create(_ directory: URL) throws {
        #if os(iOS)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var address = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try address.setResourceValues(values)
        #else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #endif
    }

    static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    private func prune(_ directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
        let entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }; var count = entries.count
        for (file, bytes, _) in entries {
            if total <= budget && count <= 64 { break }
            try FileManager.default.removeItem(at: file); total -= bytes; count -= 1
        }
    }
}

enum CatalogueCachePolicy {
    static func ttl(_ url: URL) -> TimeInterval? {
        let path = url.path
        if ["/v1/me/tracks", "/v1/me/albums", "/v1/me/playlists", "/v1/me/following", "/v1/me/shows", "/v1/me/episodes"].contains(path) { return 300 }
        if ["/v1/albums/", "/v1/artists/", "/v1/shows/", "/v1/tracks/", "/v1/episodes/", "/v1/playlists/"].contains(where: path.hasPrefix) { return 300 }
        return nil // Never cache grants, profiles, membership, devices or playback.
    }
}
