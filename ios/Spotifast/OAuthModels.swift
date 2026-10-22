import Foundation

enum Grant: String, Codable, Sendable { case web, playback }

enum TokenForm {
    static func encode(_ fields: [String: String]) -> Data {
        var body = URLComponents()
        body.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        // OAuth form bodies interpret a literal plus as a space.
        return Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
}

struct Tokens: Codable, Sendable {
    var access: String
    var refresh: String
    var expires: Date
    var clientID: String
}

enum OAuthCallback {
    static func code(from url: URL, state: String) throws -> String {
        guard url.scheme == "spotifast-ios", url.host == "oauth", url.path == "/callback",
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.filter({ $0.name == "state" }).count == 1,
              parts.queryItems?.first(where: { $0.name == "state" })?.value == state else {
            throw AppError.message("Sign-in callback did not match this session")
        }
        if parts.queryItems?.contains(where: { $0.name == "error" }) == true { throw AppError.message("Spotify authorization was declined") }
        guard parts.queryItems?.filter({ $0.name == "code" }).count == 1,
              let code = parts.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 4096,
              !code.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AppError.message("Spotify did not return an authorization code")
        }
        return code
    }
}

enum WebAPIAddress {
    static func url(_ path: String) throws -> URL {
        let url = path.hasPrefix("https://") ? URL(string: path) : URL(string: "https://api.spotify.com/v1/" + path)
        guard let url, url.scheme == "https", url.host == "api.spotify.com",
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
              url.path.hasPrefix("/v1/"), !url.pathComponents.contains("..") else {
            throw AppError.message("Refused an unexpected Spotify API address")
        }
        return url
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
