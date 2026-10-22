import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor SpotifyAPI {
    let oauth: any OAuthAccess
    private var session: URLSession
    private var generation = 0
    private var cooldown = Date.distantPast
    private var cacheScope: CacheScope?
    private var catalogueRevision = 0
    init(oauth: any OAuthAccess) {
        self.oauth = oauth
        session = Self.makeSession()
    }
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    func configureCache(account: String) async throws {
        let epoch = generation
        let scope = try await CacheStore.shared.open(account: account)
        guard epoch == generation else { throw CancellationError() }
        cacheScope = scope
    }
    func audioCacheDirectory() -> String? { cacheScope?.audioDirectory.path }
    func invalidate() async {
        generation += 1; cooldown = .distantPast
        catalogueRevision += 1; cacheScope = nil
        let oldSession = session; session = Self.makeSession()
        // Cancelling an enumerated task list races with requests for the next
        // account. Retire the entire old session instead.
        oldSession.invalidateAndCancel()
        try? await CacheStore.shared.close(clear: true)
    }
    static func url(_ path: String) throws -> URL {
        try WebAPIAddress.url(path)
    }
    func request(_ path: String, method: String = "GET", body: JSON? = nil, fresh: Bool = false) async throws -> JSON {
        let epoch = generation
        let url = try Self.url(path)
        let scope = cacheScope; let revision = catalogueRevision
        let ttl = method == "GET" ? CatalogueCachePolicy.ttl(url) : nil
        if !fresh, ttl != nil, let scope, let cached = await CacheStore.shared.read(url.absoluteString, scope: scope) {
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            if revision == catalogueRevision { return cached }
        }
        if method != "GET" {
            catalogueRevision += 1
            if let scope { try? await CacheStore.shared.invalidateMetadata(scope: scope) }
        }
        var refreshed = false
        var forceRefresh = false
        var rateRetries = 0
        while true {
            try Task.checkCancellation()
            let wait = cooldown.timeIntervalSinceNow
            if wait > 0 {
                guard method == "GET" else { throw AppError.message("Spotify is limiting requests. Try again after \(cooldown.formatted(date: .omitted, time: .standard)).") }
                try await Task.sleep(for: .seconds(wait))
            }
            if cooldown.timeIntervalSinceNow > 0 { continue }
            guard epoch == generation else { throw CancellationError() }
            let access = try await oauth.access(.web, force: forceRefresh)
            forceRefresh = false
            guard epoch == generation else { throw CancellationError() }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await session.data(for: request)
            guard epoch == generation else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw AppError.message("Spotify returned an invalid response") }
            if http.statusCode == 401 && !refreshed { refreshed = true; forceRefresh = true; continue }
            if http.statusCode == 429 {
                let seconds = max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "30") ?? 30)
                cooldown = Date().addingTimeInterval(min(seconds, 86_400))
                if method == "GET", rateRetries < 1, seconds <= 120 { rateRetries += 1; continue }
                throw AppError.message("Spotify is limiting requests. Try again after \(cooldown.formatted(date: .omitted, time: .standard)).")
            }
            guard (200...299).contains(http.statusCode) else {
                switch http.statusCode {
                case 401: throw AppError.message("Spotify sign-in is no longer valid. Sign in again in Settings.")
                case 403: throw AppError.message("Spotify refused this request. Check the app's allowed users, permissions, Premium plan, and Development Mode restrictions.")
                case 404: throw AppError.message("Spotify could not find this item or an active playback device.")
                default: throw AppError.message("Spotify request failed (HTTP \(http.statusCode)). Try again.")
                }
            }
            if data.isEmpty { return .null }
            let value = try JSONDecoder().decode(JSON.self, from: data)
            if let ttl, let scope, revision == catalogueRevision { try? await CacheStore.shared.write(value, key: url.absoluteString, ttl: ttl, scope: scope) }
            guard epoch == generation else { throw CancellationError() }
            return value
        }
    }
    func library(_ section: LibrarySection, next: String? = nil, fresh: Bool = false) async throws -> ItemPage {
        var json = try await request(next ?? section.path, fresh: fresh)
        if section == .artists { json = json["artists"] }
        return ItemPage(json, wrapper: section.wrapper)
    }
    func membership(_ uri: String) async throws -> Bool {
        let result = try await request("me/library/contains?uris=" + Self.escape(uri))
        guard let member = result.array.first?.bool else { throw AppError.message("Spotify did not return the library status") }; return member
    }
    func save(_ uri: String, saved: Bool) async throws { _ = try await request("me/library?uris=" + Self.escape(uri), method: saved ? "PUT" : "DELETE") }
    func search(_ query: String, kind: String, offset: Int = 0) async throws -> ItemPage {
        let result = try await request("search?q=\(Self.escape(query))&type=\(kind)&limit=10&offset=\(offset)")
        let key = kind == "show" ? "shows" : kind == "artist" ? "artists" : kind + "s"
        return ItemPage(result[key])
    }
    func collection(_ item: SpotifyItem, next: String? = nil, fresh: Bool = false) async throws -> ItemPage {
        let path: String
        switch item.kind {
        case "playlist": path = "playlists/\(item.resourceID)/items?limit=30"
        case "album": path = "albums/\(item.resourceID)/tracks?limit=30"
        case "show": path = "shows/\(item.resourceID)/episodes?limit=30"
        case "artist": path = "artists/\(item.resourceID)/albums?limit=30&include_groups=album,single"
        default: throw AppError.message("This item does not have a collection page")
        }
        return ItemPage(try await request(next ?? path, fresh: fresh))
    }
    func devices() async throws -> [Device] {
        let json = try await request("me/player/devices")
        return json["devices"].array.compactMap { v in
            guard let id = v["id"].string, let name = v["name"].string else { return nil }
            return Device(id: id, name: name, restricted: v["is_restricted"].bool ?? false, active: v["is_active"].bool ?? false, supportsVolume: v["supports_volume"].bool ?? false)
        }
    }
    func playback() async throws -> Playback? {
        let value = try await request("me/player?additional_types=track,episode")
        guard value != .null else { return nil }
        var result = Playback()
        result.item = SpotifyItem(value["item"])
        result.position = value["progress_ms"].int ?? 0
        result.playing = value["is_playing"].bool ?? false
        result.shuffle = value["shuffle_state"].bool ?? false
        result.repeatMode = value["repeat_state"].string ?? "off"
        result.volume = value["device"]["volume_percent"].int ?? 100
        result.deviceID = value["device"]["id"].string
        result.deviceName = value["device"]["name"].string ?? "Spotify"
        return result
    }
    func control(_ path: String, method: String = "PUT", body: JSON? = nil, device: String? = nil) async throws {
        let suffix = device.map { (path.contains("?") ? "&" : "?") + "device_id=" + Self.escape($0) } ?? ""
        _ = try await request("me/player/" + path + suffix, method: method, body: body)
    }
    func transfer(_ device: String) async throws { _ = try await request("me/player", method: "PUT", body: .object(["device_ids": .strings([device]), "play": .bool(false)])) }
    func queue() async throws -> [SpotifyItem] { try await request("me/player/queue")["queue"].array.compactMap(SpotifyItem.init) }
    func createPlaylist(name: String) async throws -> SpotifyItem {
        let value = try await request("me/playlists", method: "POST", body: .object(["name": .string(name), "public": .bool(false)]))
        guard let item = SpotifyItem(value) else { throw AppError.message("Spotify did not return the new playlist") }; return item
    }
    func editPlaylist(_ item: SpotifyItem, name: String, description: String, isPublic: Bool) async throws {
        _ = try await request("playlists/\(item.resourceID)", method: "PUT", body: .object(["name": .string(name), "description": .string(description), "public": .bool(isPublic)]))
    }
    func add(_ item: SpotifyItem, to playlist: SpotifyItem) async throws {
        _ = try await request("playlists/\(playlist.resourceID)/items", method: "POST", body: .object(["uris": .strings([item.uri])]))
    }
    func updatePlaylistItems(_ item: SpotifyItem, body: JSON, method: String) async throws {
        guard item.kind == "playlist", ["PUT", "DELETE"].contains(method) else { throw AppError.message("Invalid playlist edit") }
        _ = try await request("playlists/\(item.resourceID)/items", method: method, body: body)
    }
    static func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
}
