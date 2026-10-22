import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol OAuthAccess: Sendable {
    func access(_ grant: Grant, force: Bool) async throws -> String
}

// Authenticated requests never forward a bearer or token form to a redirect.
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
