import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

// A shareable link provided by Spotify. Shape validation does not establish
// whether a Jam exists, is active, or can be joined by a particular account.
struct JamInvite: Hashable, Identifiable, Sendable {
    let link: String
    let url: URL
    let shortened: Bool
    var id: String { link }
    var message: Data { Data(link.utf8) }
    init(_ text: String) throws {
        guard let pointer = text.withCString({ sf_parse_jam_invite($0, text.utf8.count) }) else {
            throw AppError.message("Paste the full HTTPS invite copied from Spotify's Jam screen: an open.spotify.com/socialsession link or a spotify.link short invite.")
        }
        defer { sf_string_free(pointer) }
        struct Payload: Decodable { let url: String; let shortened: Bool }
        let value = try JSONDecoder().decode(Payload.self, from: Data(bytes: pointer, count: strlen(pointer)))
        guard let url = URL(string: value.url) else { throw AppError.message("This Spotify invite address could not be opened") }
        link = value.url; self.url = url; shortened = value.shortened
    }
}

actor JamQRRenderer {
    static let shared = JamQRRenderer()
    private var context: CIContext?
    func image(for invite: JamInvite) throws -> UIImage {
        try Task.checkCancellation()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = invite.message
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { throw AppError.message("The QR code could not be created. You can still share the invite link.") }
        // Four white modules on every edge, black on white in all themes.
        // Integer scaling preserves the grid, including in the shared image.
        let extent = output.extent.integral
        let bounds = CGRect(x: 0, y: 0, width: extent.width + 8, height: extent.height + 8)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: bounds)
        let moved = output.transformed(by: CGAffineTransform(translationX: 4 - extent.minX, y: 4 - extent.minY))
        let bordered = moved.composited(over: white).cropped(to: bounds)
        let scale = max(1, (768 / bounds.width).rounded(.down))
        if context == nil { context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false]) }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let side = Int(bounds.width * scale)
        guard let base = context?.createCGImage(bordered, from: bounds, format: .RGBA8, colorSpace: colorSpace),
              let bitmap = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw AppError.message("The QR code could not be drawn. Share the invite link instead.") }
        bitmap.interpolationQuality = .none
        bitmap.draw(base, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        guard let image = bitmap.makeImage() else { throw AppError.message("The QR image could not be created. Share the invite link instead.") }
        try Task.checkCancellation()
        return UIImage(cgImage: image)
    }
}
