import ImageIO
import SwiftUI
import UIKit

actor ArtworkPipeline {
    static let shared = ArtworkPipeline()
    private let cache = NSCache<NSString, UIImage>()
    private let session: URLSession
    init() {
        cache.totalCostLimit = 12 * 1024 * 1024; cache.countLimit = 100
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 3
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        session = URLSession(configuration: config)
    }
    func image(_ url: URL, pixels: Int) async throws -> UIImage {
        guard url.scheme == "https" else { throw AppError.message("Artwork requires HTTPS") }
        let key = "\(url.absoluteString):\(pixels)" as NSString
        if let image = cache.object(forKey: key) { return image }
        var request = URLRequest(url: url); request.setValue("image/*", forHTTPHeaderField: "Accept")
        // Bound compressed data as it arrives, including servers without a
        // Content-Length. This prevents a large cover exhausting phone memory.
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= 4_194_304 else { throw AppError.message("Artwork could not load") }
        var data = Data(); data.reserveCapacity(65_536)
        for try await byte in bytes {
            if data.count >= 4_194_304 { throw AppError.message("Artwork is too large") }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw AppError.message("Artwork format is unavailable") }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
        return image
    }
    func clear() { cache.removeAllObjects() }
}

struct Artwork: View {
    let url: URL?
    var size: CGFloat = 48
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: "\(url?.absoluteString ?? "none"):\(Int(size * scale))") {
            image = nil
            guard let url else { return }
            do {
                let value = try await ArtworkPipeline.shared.image(url, pixels: min(900, Int(size * scale)))
                try Task.checkCancellation(); image = value
            } catch { }
        }
    }
}
