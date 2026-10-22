import XCTest
import UIKit

// Launches the actual application without an account, stub server, alternate
// backend or demo mode. Only local input validation is exercised here.
final class SignInUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSignInRemainsReachableInPortraitAndLandscape() {
        let app = XCUIApplication(); app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let field = app.textFields["signin.clientID"]
            XCTAssertTrue(app.navigationBars["Spotifast"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
            let tagline = app.staticTexts["signin.tagline"]
            reveal(tagline, in: app)
            XCTAssertTrue(tagline.isHittable)
            // The two explicit lines must not collapse to a truncated row.
            XCTAssertGreaterThan(tagline.frame.height, 60)
            capture(app, name: "SignIn-Heading-\(orientation.rawValue)")
            reveal(field, in: app); XCTAssertTrue(field.isHittable)
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            capture(app, name: "SignIn-Keyboard-\(orientation.rawValue)")
            dismissKeyboard(in: app)
            let submit = app.buttons["signin.submit"]
            reveal(submit, in: app); XCTAssertTrue(submit.isHittable)
            capture(app, name: "SignIn-\(orientation.rawValue)")
        }
    }

    func testInvalidClientIDProducesADismissibleNativeError() {
        let app = XCUIApplication(); app.launch()
        defer { app.terminate() }
        let field = app.textFields["signin.clientID"]
        XCTAssertTrue(app.navigationBars["Spotifast"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
        reveal(field, in: app); field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "invalid")
        dismissKeyboard(in: app)
        let submit = app.buttons["signin.submit"]
        reveal(submit, in: app); submit.tap()
        let alert = app.alerts["Spotifast"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Client ID")).firstMatch.exists)
        capture(app, name: "SignIn-ValidationError")
        alert.buttons["OK"].tap()
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
    }

    func testLargestTextSignInCanScrollToItsPrimaryAction() {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        app.launch(); defer { app.terminate() }
        let field = app.textFields["signin.clientID"]
        XCTAssertTrue(app.navigationBars["Spotifast"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.firstMatch.debugDescription)
        reveal(field, in: app); XCTAssertTrue(field.isHittable)
        let submit = app.buttons["signin.submit"]
        reveal(submit, in: app); XCTAssertTrue(submit.isHittable)
        capture(app, name: "SignIn-LargestText")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        // Form lazily creates offscreen rows. Waiting for an element before
        // scrolling cannot find it at the largest text size. Scroll the actual
        // form, never the application/keyboard surface.
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            form.swipeDown()
        }
        for _ in 0..<16 {
            if element.exists && element.isHittable { return }
            form.swipeUp()
        }
    }
    private func dismissKeyboard(in app: XCUIApplication) {
        let done = app.buttons["signin.keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
