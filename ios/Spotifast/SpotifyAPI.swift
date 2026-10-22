import Foundation

actor SpotifyAPI {
    let oauth: OAuthClient
    private var session: URLSession
    private var generation = 0
    private var cooldown = Date.distantPast
    init(oauth: OAuthClient) {
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
    func invalidate() {
        generation += 1; cooldown = .distantPast
        let oldSession = session; session = Self.makeSession()
        // Cancelling an enumerated task list races with requests for the next
        // account. Retire the entire old session instead.
        oldSession.invalidateAndCancel()
    }
    static func url(_ path: String) throws -> URL {
        let url = path.hasPrefix("https://") ? URL(string: path) : URL(string: "https://api.spotify.com/v1/" + path)
        guard let url, url.scheme == "https", url.host == "api.spotify.com", url.port == nil, url.user == nil, url.password == nil, url.path.hasPrefix("/v1/") else { throw AppError.message("Refused an unexpected Spotify API address") }
        return url
    }
    func request(_ path: String, method: String = "GET", body: JSON? = nil) async throws -> JSON {
        let epoch = generation
        let url = try Self.url(path)
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
            return try JSONDecoder().decode(JSON.self, from: data)
        }
    }
    func library(_ section: LibrarySection, next: String? = nil) async throws -> ItemPage {
        var json = try await request(next ?? section.path)
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
    func collection(_ item: SpotifyItem, next: String? = nil) async throws -> ItemPage {
        let path: String
        switch item.kind {
        case "playlist": path = "playlists/\(item.resourceID)/items?limit=30"
        case "album": path = "albums/\(item.resourceID)/tracks?limit=30"
        case "show": path = "shows/\(item.resourceID)/episodes?limit=30"
        case "artist": path = "artists/\(item.resourceID)/albums?limit=30&include_groups=album,single"
        default: throw AppError.message("This item does not have a collection page")
        }
        return ItemPage(try await request(next ?? path))
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
    static func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
}
