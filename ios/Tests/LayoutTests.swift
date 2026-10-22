import SwiftUI
import UIKit
import XCTest
@testable import Spotifast

// These are real SwiftUI hosting/layout tests, not browser approximations.
// Fixtures have no images, network requests or substitute playback backend.
// Inspect the attached native renders in Xcode's test report as well as the
// size assertions. This does not replace full-screen/device interaction tests.
@MainActor
final class LayoutTests: XCTestCase {
    func testTransportFitsCompactWidthsWithLargeTextAndRTL() throws {
        for width in [CGFloat(320), 375, 393, 430, 568] {
            for type in [DynamicTypeSize.large, .xxxLarge, .accessibility5] {
                for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                    let controls = PlayerTransportControls(playing: true, shuffle: true, repeatMode: "track") { _ in }
                        .padding(.horizontal, 24)
                        .environment(\.dynamicTypeSize, type).environment(\.layoutDirection, direction)
                    let host = UIHostingController(rootView: controls)
                    let size = host.sizeThatFits(in: CGSize(width: width, height: 2000))
                    XCTAssertLessThanOrEqual(size.width, width + 0.5, "Transport overflow: \(width), \(type), \(direction)")
                    XCTAssertGreaterThanOrEqual(size.height, 72)
                    XCTAssertLessThan(size.height, 300)
                }
            }
        }
    }
    func testCollectionTitleFitsSmallPhoneWithLargestText() throws {
        let item = try XCTUnwrap(SpotifyItem(.object([
            "uri": .string("spotify:album:fixture"), "type": .string("album"),
            "name": .string("A long collection title that must wrap without hiding the actions"),
            "artists": .array([.object(["name": .string("An artist with a long display name")])])
        ])))
        for type in [DynamicTypeSize.large, .xxLarge, .accessibility5] {
            let host = UIHostingController(rootView: CollectionHeading(item: item).padding(16).environment(\.dynamicTypeSize, type))
            let size = host.sizeThatFits(in: CGSize(width: 320, height: 3000))
            XCTAssertLessThanOrEqual(size.width, 320.5)
            XCTAssertGreaterThan(size.height, 96)
            XCTAssertLessThan(size.height, 2500)
        }
    }
    func testMiniPlayerKeepsControlsInsideCompactWidth() throws {
        let item = try XCTUnwrap(SpotifyItem(.object(["uri": .string("spotify:track:fixture"), "name": .string("A long song title that should remain readable with large text")])))
        for type in [DynamicTypeSize.large, .accessibility5] {
            let content = MiniPlayerContent(item: item, deviceName: "A long Spotify Connect device name", playing: false, open: {}, toggle: {}, next: {})
                .environment(\.dynamicTypeSize, type)
            let host = UIHostingController(rootView: content)
            let size = host.sizeThatFits(in: CGSize(width: 320, height: 2000))
            XCTAssertLessThanOrEqual(size.width, 320.5)
            XCTAssertLessThan(size.height, 340, "The mini player must leave room for browsing on a small phone")
            try attach(content, size: CGSize(width: 320, height: 360), name: "MiniPlayer-320-\(type)")
        }
    }
    func testAttachNativeTransportRendersForReview() throws {
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(320), 430] {
                for type in [DynamicTypeSize.large, .accessibility5] {
                    let controls = PlayerTransportControls(playing: true, shuffle: true, repeatMode: "track") { _ in }
                        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(uiColor: .systemBackground))
                        .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, type)
                    try attach(controls, size: CGSize(width: width, height: 320), name: "Transport-\(width)-\(scheme)-\(type)")
                }
            }
        }
    }
    func testJamQRCardFitsCompactWidthInBothThemes() async throws {
        let image = try await JamQRRenderer.shared.image(for: JamInvite("https://spotify.link/TestInvite"))
        for scheme in [ColorScheme.light, .dark] {
            let content = JamQRCard(image: image).padding(20).environment(\.colorScheme, scheme)
            let host = UIHostingController(rootView: content)
            let size = host.sizeThatFits(in: CGSize(width: 320, height: 1000))
            XCTAssertLessThanOrEqual(size.width, 320.5)
            XCTAssertLessThanOrEqual(size.height, 320.5)
            try attach(content, size: CGSize(width: 320, height: 360), name: "JamQR-320-\(scheme)")
        }
    }
    func testNativeFullPlayerSettingsAndJamScreensRenderAtPhoneSizes() throws {
        // Layout-only inputs for real production views. No grants are restored,
        // no server is substituted, and no playback/API success is asserted.
        let store = AppStore()
        store.playback.item = try XCTUnwrap(SpotifyItem(.object([
            "uri": .string("spotify:track:fixture"),
            "name": .string("A long song title to check the complete player layout"),
            "artists": .array([.object(["name": .string("An artist with a long display name")])]),
            "duration_ms": .number(180_000)
        ])))
        store.playback.deviceName = "This iPhone with a long device name"
        store.playback.isLocal = true
        store.preferences.eqEnabled = true
        for scheme in [ColorScheme.light, .dark] {
            for (size, type) in [(CGSize(width: 320, height: 568), DynamicTypeSize.large),
                                 (CGSize(width: 430, height: 932), .accessibility5),
                                 (CGSize(width: 568, height: 320), .large)] {
                let screens: [(String, AnyView)] = [
                    ("Player", AnyView(PlayerView())),
                    ("Settings", AnyView(SettingsView())),
                    ("Equalizer", AnyView(EqualizerView())),
                    ("Jam", AnyView(JamView()))
                ]
                for (name, screen) in screens {
                    let content = NavigationStack { screen }
                        .environmentObject(store).environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, type)
                    try attach(content, size: size, name: "Screen-\(name)-\(Int(size.width))x\(Int(size.height))-\(scheme)-\(type)", includeScrollEnd: true)
                }
            }
        }
    }
    private func attach<Content: View>(_ content: Content, size: CGSize, name: String, includeScrollEnd: Bool = false) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        func capture(_ title: String) {
            var drew = false
            let result = UIGraphicsImageRenderer(size: size).image { _ in
                drew = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drew, "Native render failed: \(title)")
            let attachment = XCTAttachment(image: result); attachment.name = title; attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture(name)
        if includeScrollEnd {
            func scrolls(in view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls(in: $0) }
            }
            let scroll = try XCTUnwrap(scrolls(in: host.view).max { $0.contentSize.height < $1.contentSize.height }, "Screen must retain its native scrolling container")
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height, "Long content must remain scrollable: \(name)")
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1, "Horizontal content overflow: \(name)")
            // Form estimates offscreen row heights. A jump can create more rows
            // and move its actual end, especially at accessibility text sizes.
            // Require two stable layouts at the real end before capturing it.
            var settled = 0
            for _ in 0..<24 {
                scroll.layoutIfNeeded()
                let end = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                scroll.setContentOffset(CGPoint(x: 0, y: end), animated: false)
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let updatedEnd = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                if abs(end - updatedEnd) < 1 && abs(scroll.contentOffset.y - updatedEnd) < 1 {
                    settled += 1
                    if settled >= 2 { break }
                } else { settled = 0 }
            }
            XCTAssertGreaterThanOrEqual(settled, 2, "Scroll end did not stabilize: \(name), offset=\(scroll.contentOffset.y), content=\(scroll.contentSize), viewport=\(scroll.bounds.size)")
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1, "Horizontal content overflow after scrolling: \(name)")
            XCTAssertGreaterThan(scroll.contentOffset.y, -scroll.adjustedContentInset.top + 1, "The lower controls must be reachable by scrolling: \(name)")
            capture(name + "-End")
        }
    }
}
