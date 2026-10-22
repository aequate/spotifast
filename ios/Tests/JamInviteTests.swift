import CoreImage
import UIKit
import XCTest
@testable import Spotifast

final class JamInviteTests: XCTestCase {
    func testInvitePreservesItsQueryAcrossTheRustBridge() throws {
        let direct = "https://open.spotify.com/socialsession/TestSession_123?si=a%2Bb%3D&opaque=+%23%25"
        let invite = try JamInvite(" \n" + direct + "\t")
        XCTAssertEqual(invite.link, direct)
        XCTAssertEqual(invite.url.absoluteString, direct)
        XCTAssertEqual(invite.message, Data(direct.utf8))
        XCTAssertFalse(invite.shortened)
        let short = try JamInvite("https://spotify.link/TestInvite?si=+%2B%3D")
        XCTAssertTrue(short.shortened)
        XCTAssertEqual(short.link, short.url.absoluteString)
    }
    func testInviteRejectsMusicLinksMalformedHostsAndOversizedInput() {
        for text in ["https://open.spotify.com/track/test", "https://evil.test/socialsession/test", "https://open.spotify.com.evil.test/socialsession/test", "https://open.spotify.com/socialsession/test\0discarded", "https://spotify.link/test?si=%00", String(repeating: "x", count: 5000)] {
            XCTAssertThrowsError(try JamInvite(text))
        }
    }
    func testNativeQRDecodesToTheExactInviteAndHasOpaqueWhiteEdges() async throws {
        let prefix = "https://open.spotify.com/socialsession/TestSession?si="
        let addresses = [
            prefix + "a%2Bb%3D&literal=+%23%25",
            "https://spotify.link/TestInvite?si=a%2Bb%3D",
            prefix + String(repeating: "x", count: 1024 - prefix.utf8.count)
        ]
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for address in addresses {
            let image = try await JamQRRenderer.shared.image(for: JamInvite(address))
            let cg = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(cg.width, cg.height)
            XCTAssertLessThanOrEqual(cg.width, 768)
            let codes = detector.features(in: CIImage(cgImage: cg)).compactMap { $0 as? CIQRCodeFeature }
            XCTAssertEqual(codes.count, 1)
            XCTAssertEqual(codes.first?.messageString, address)
            XCTAssertEqual(cg.bitsPerPixel, 32)
            let data = try XCTUnwrap(cg.dataProvider?.data) as Data
            var binaryAndOpaque = true
            for y in 0..<cg.height {
                for x in 0..<cg.width {
                    let offset = y * cg.bytesPerRow + x * 4
                    if data[offset + 3] != 255 || ![data[offset], data[offset + 1], data[offset + 2]].allSatisfy({ $0 == 0 || $0 == 255 }) { binaryAndOpaque = false }
                }
            }
            XCTAssertTrue(binaryAndOpaque, "QR pixels must have no translucent or interpolated edges")
            for y in 0..<cg.height {
                for x in [0, cg.width - 1] {
                    let offset = y * cg.bytesPerRow + x * 4
                    XCTAssertEqual(Array(data[offset..<offset + 4]), [255, 255, 255, 255])
                }
            }
            for x in 0..<cg.width {
                for y in [0, cg.height - 1] {
                    let offset = y * cg.bytesPerRow + x * 4
                    XCTAssertEqual(Array(data[offset..<offset + 4]), [255, 255, 255, 255])
                }
            }
        }
    }
}
