import Foundation

// Small, lossless JSON adapter for Spotify's nullable and versioned responses.
enum JSON: Codable, Equatable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([JSON].self) { self = .array(v) }
        else { self = .object(try value.decode([String: JSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    subscript(_ key: String) -> JSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var int: Int? { if case .number(let v) = self, v.isFinite, v > Double(Int.min), v < Double(Int.max) { return Int(v) }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var array: [JSON] { if case .array(let v) = self { return v }; return [] }
    static func strings(_ values: [String]) -> JSON { .array(values.map(JSON.string)) }
}

struct SpotifyItem: Identifiable, Hashable, Sendable {
    var id: String { uri }
    let uri: String
    let name: String
    let subtitle: String
    let album: String?
    let kind: String
    let image: URL?
    let duration: Int
    let playable: Bool
    let owner: String?
    let collaborative: Bool
    let description: String
    var resourceID: String { uri.components(separatedBy: ":").last ?? "" }
    var isAudio: Bool { kind == "track" || kind == "episode" }
    init?(_ value: JSON) {
        guard let uri = value["uri"].string, let name = value["name"].string else { return nil }
        self.uri = uri; self.name = name
        kind = value["type"].string ?? uri.components(separatedBy: ":").dropFirst().first ?? "track"
        let artists = value["artists"].array.compactMap { $0["name"].string }.joined(separator: ", ")
        subtitle = artists.isEmpty ? (value["publisher"].string ?? value["owner"]["display_name"].string ?? kind.capitalized) : artists
        album = value["album"]["name"].string ?? value["show"]["name"].string
        let images = value["images"].array.isEmpty ? value["album"]["images"].array : value["images"].array
        let sorted = images.sorted { ($0["width"].int ?? 640) < ($1["width"].int ?? 640) }
        if let selected = sorted.first(where: { ($0["width"].int ?? 640) >= 160 }) ?? sorted.last, let address = selected["url"].string { image = URL(string: address) } else { image = nil }
        duration = value["duration_ms"].int ?? 0
        playable = value["is_playable"].bool != false && value["is_local"].bool != true && !uri.hasPrefix("spotify:local:") && value["restrictions"]["reason"].string == nil
        owner = value["owner"]["id"].string
        collaborative = value["collaborative"].bool ?? false
        description = value["description"].string ?? ""
    }
}

struct ItemRow: Identifiable, Sendable {
    let item: SpotifyItem
    let position: Int
    var id: String { "\(position):\(item.uri)" }
}

struct ItemPage: Sendable {
    let rows: [ItemRow]
    let next: String?
    let endOffset: Int
    init(_ value: JSON, wrapper: String? = nil) {
        let offset = value["offset"].int ?? 0
        endOffset = offset + value["items"].array.count
        rows = value["items"].array.enumerated().compactMap { i, raw in
            let item: JSON
            if let wrapper { item = raw[wrapper] }
            else if raw["item"] != .null { item = raw["item"] }
            else if raw["track"] != .null { item = raw["track"] }
            else { item = raw }
            return SpotifyItem(item).map { ItemRow(item: $0, position: offset + i) }
        }
        next = value["next"].string
    }
}

struct Profile: Sendable {
    let id: String
    let name: String
    let premium: Bool?
    init(_ value: JSON) throws {
        guard let id = value["id"].string else { throw AppError.message("Spotify did not return an account ID") }
        self.id = id; name = value["display_name"].string ?? id
        // Development Mode no longer returns product. Unknown must not be
        // treated as Free: the streaming service verifies eligibility.
        premium = value["product"].string.map { $0 == "premium" }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case playlists = "Playlists", songs = "Liked Songs", albums = "Albums", artists = "Artists", shows = "Podcasts", episodes = "Episodes"
    var id: String { rawValue }
    var path: String {
        switch self {
        case .playlists: return "me/playlists?limit=30"
        case .songs: return "me/tracks?limit=30"
        case .albums: return "me/albums?limit=30"
        case .artists: return "me/following?type=artist&limit=30"
        case .shows: return "me/shows?limit=30"
        case .episodes: return "me/episodes?limit=30"
        }
    }
    var wrapper: String? {
        switch self { case .songs: return "track"; case .albums: return "album"; case .shows: return "show"; case .episodes: return "episode"; default: return nil }
    }
}

struct EngineSnapshot: Decodable, Sendable {
    let generation: UInt64
    struct QueueRow: Decodable, Sendable { let uri: String; let manual: Bool }
    let connected: Bool
    let active: Bool
    let connecting: Bool
    let deviceId: String
    let username: String
    let playing: Bool
    let loading: Bool
    let uri: String?
    let title: String
    let artists: [String]
    let album: String
    let coverUrl: String?
    let durationMs: Int
    let positionMs: Int
    let shuffle: Bool
    let `repeat`: String
    let volume: Int
    let contextUri: String
    let queue: [QueueRow]
    let error: String?
    let revision: UInt64
    let audioRunning: Bool
    let underruns: Int
    let lyrics: JSON?
    let lyricsUri: String?
}

struct Playback: Sendable {
    var item: SpotifyItem?
    var playing = false
    var position = 0
    var updated = Date()
    var shuffle = false
    var repeatMode = "off"
    var volume = 100
    var deviceID: String?
    var deviceName = "No active device"
    var isLocal = false
    var progress: Int { min(item?.duration ?? 0, max(0, position + (playing ? Int(Date().timeIntervalSince(updated) * 1000) : 0))) }
}

struct Device: Identifiable, Sendable {
    let id: String
    let name: String
    let restricted: Bool
    let active: Bool
    let supportsVolume: Bool
}
