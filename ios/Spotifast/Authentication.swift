import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum Grant: String, Codable, Sendable { case web, playback }

enum TokenForm {
    static func encode(_ fields: [String: String]) -> Data {
        var body = URLComponents()
        body.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents follows URI query rules, where '+' is literal. OAuth
        // form bodies decode '+' as a space, so it must be escaped explicitly.
        return Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
}

struct Tokens: Codable, Sendable {
    var access: String
    var refresh: String
    var expires: Date
    var clientID: String
}

enum Keychain {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "local.spotifast.ios") + ".credentials" }
    static func read(_ name: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AppError.message("Keychain is unavailable (\(status)). Unlock your iPhone and try again.") }
        return result as? Data
    }
    static func write(_ data: Data, name: String) throws {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(key.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw AppError.message("Could not save authorization to Keychain") }
        } else if status != errSecSuccess { throw AppError.message("Could not update authorization in Keychain") }
    }
    static func delete(_ name: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.message("Could not remove authorization from Keychain") }
    }
}

struct PKCE {
    let verifier: String
    let state: String
    static let redirect = "spotifast-ios://oauth/callback"
    init() throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppError.message("Secure random generation failed") }
            return Data(bytes).base64URL
        }
        verifier = try random(); state = try random()
    }
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }
    func url(clientID: String, grant: Grant) throws -> URL {
        let web = "user-read-private user-read-playback-state user-modify-playback-state user-read-currently-playing user-library-read user-library-modify playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private user-follow-read user-follow-modify user-read-recently-played user-top-read"
        var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
        url.queryItems = ["client_id": clientID, "response_type": "code", "redirect_uri": Self.redirect, "code_challenge_method": "S256", "code_challenge": challenge, "state": state, "scope": grant == .web ? web : "streaming user-read-private", "show_dialog": "true"].map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let result = url.url else { throw AppError.message("Invalid sign-in URL") }; return result
    }
    func code(from url: URL) throws -> String {
        guard url.scheme == "spotifast-ios", url.host == "oauth", url.path == "/callback",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.filter({ $0.name == "state" }).count == 1,
              parts.queryItems?.first(where: { $0.name == "state" })?.value == state else { throw AppError.message("Sign-in callback did not match this session") }
        if parts.queryItems?.contains(where: { $0.name == "error" }) == true { throw AppError.message("Spotify authorization was declined") }
        guard parts.queryItems?.filter({ $0.name == "code" }).count == 1,
              let code = parts.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw AppError.message("Spotify did not return an authorization code") }
        return code
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

// URLSession never follows redirects with an authorization header or a POST.
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

actor OAuthClient {
    private var accountID: String?
    private var tokens: [Grant: Tokens] = [:]
    private var refreshes: [Grant: Task<Tokens, Error>] = [:]
    private var generation = AccountEpoch()
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }
    func restore() throws {
        for grant in [Grant.web, .playback] {
            if let data = try Keychain.read(grant.rawValue) { tokens[grant] = try JSONDecoder().decode(Tokens.self, from: data) }
        }
    }
    private func persist(_ token: Tokens, grant: Grant) throws { try Keychain.write(JSONEncoder().encode(token), name: grant.rawValue); tokens[grant] = token }
    func authorizationEpoch() -> UUID { generation.value }
    func exchange(code: String, flow: PKCE, clientID: String, grant: Grant, epoch: UUID) async throws {
        guard generation.accepts(epoch) else { throw CancellationError() }
        let token = try await request(["grant_type": "authorization_code", "code": code, "redirect_uri": PKCE.redirect, "client_id": clientID, "code_verifier": flow.verifier], clientID: clientID, oldRefresh: "")
        guard generation.accepts(epoch) else { throw CancellationError() }
        try persist(token, grant: grant)
    }
    func access(_ grant: Grant, force: Bool = false) async throws -> String {
        try Task.checkCancellation()
        guard let token = tokens[grant] else { throw AppError.message(grant == .web ? "Sign in to Spotify first" : "Authorize playback in Settings first") }
        if !force && token.expires.timeIntervalSinceNow > 90 { return token.access }
        let epoch = generation.value
        if let task = refreshes[grant] {
            let refreshed = try await task.value
            guard generation.accepts(epoch) else { throw CancellationError() }
            return refreshed.access
        }
        let task = Task { try await request(["grant_type": "refresh_token", "refresh_token": token.refresh, "client_id": token.clientID], clientID: token.clientID, oldRefresh: token.refresh) }
        refreshes[grant] = task
        do {
            let refreshed = try await task.value
            guard generation.accepts(epoch) else { throw CancellationError() }
            refreshes[grant] = nil
            try persist(refreshed, grant: grant)
            return refreshed.access
        } catch {
            if generation.accepts(epoch) { refreshes[grant] = nil }
            throw error
        }
    }
    private func request(_ fields: [String: String], clientID: String, oldRefresh: String) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"; request.httpBody = TokenForm.encode(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AppError.message("Spotify authorization expired or was rejected. Sign in again.") }
        let value = try JSONDecoder().decode(JSON.self, from: data)
        guard let access = value["access_token"].string else { throw AppError.message("Spotify returned an invalid authorization response") }
        let refresh = value["refresh_token"].string ?? oldRefresh
        guard !refresh.isEmpty else { throw AppError.message("Spotify did not grant persistent authorization") }
        return Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(TimeInterval(value["expires_in"].int ?? 3600)), clientID: clientID)
    }
    func playbackCredentials() throws -> JSON? { try Keychain.read("librespot").map { try JSONDecoder().decode(JSON.self, from: $0) } }
    func verifyAccount(_ account: String) { accountID = account }
    func clearSavedPlayback() throws { try Keychain.delete("librespot") }
    func savePlaybackCredentials(_ data: Data, account: String) throws {
        guard accountID == account else { throw CancellationError() }
        try Keychain.write(data, name: "librespot")
    }
    func clearPlayback() throws { try Keychain.delete("librespot"); try Keychain.delete(Grant.playback.rawValue); tokens[.playback] = nil }
    func signOut() throws {
        generation.invalidate(); accountID = nil; refreshes.values.forEach { $0.cancel() }; refreshes.removeAll(); tokens.removeAll()
        var failure: Error?
        for name in ["web", "playback", "librespot"] { do { try Keychain.delete(name) } catch { failure = error } }
        if let failure { throw failure }
    }
}

@MainActor
final class BrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var requestID: UUID?
    private var pending: CheckedContinuation<URL, Error>?
    func cancel() {
        let current = session
        session = nil; requestID = nil
        let continuation = pending; pending = nil
        current?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
    private func complete(_ id: UUID, result: Result<URL, Error>) {
        guard requestID == id, let continuation = pending else { return }
        session = nil; pending = nil
        continuation.resume(with: result)
    }
    func signIn(clientID: String, grant: Grant, oauth: OAuthClient) async throws {
        guard requestID == nil else { throw AppError.message("Finish the current Spotify sign-in first") }
        let id = UUID(); requestID = id
        defer { if requestID == id { requestID = nil } }
        let flow = try PKCE()
        let url = try flow.url(clientID: clientID, grant: grant)
        // Capture before opening the browser. A callback from an earlier
        // account must never persist a grant after sign-out.
        let epoch = await oauth.authorizationEpoch()
        guard requestID == id else { throw CancellationError() }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "spotifast-ios") { [weak self] url, error in
                Task { @MainActor in
                    if let url { self?.complete(id, result: .success(url)) }
                    else { self?.complete(id, result: .failure(error ?? CancellationError())) }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() { complete(id, result: .failure(AppError.message("Could not open Spotify sign-in"))) }
        }
        guard requestID == id else { throw CancellationError() }
        try await oauth.exchange(code: flow.code(from: callback), flow: flow, clientID: clientID, grant: grant, epoch: epoch)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
