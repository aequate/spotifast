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
            XCTAssertTrue(field.waitForExistence(timeout: 15))
            reveal(field, in: app); XCTAssertTrue(field.isHittable)
            field.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let submit = app.buttons["signin.submit"]
            reveal(submit, in: app); XCTAssertTrue(submit.isHittable)
            capture(app, name: "SignIn-\(orientation.rawValue)")
        }
    }

    func testInvalidClientIDProducesADismissibleNativeError() {
        let app = XCUIApplication(); app.launch()
        defer { app.terminate() }
        let field = app.textFields["signin.clientID"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        reveal(field, in: app); field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "invalid")
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
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        reveal(field, in: app); XCTAssertTrue(field.isHittable)
        let submit = app.buttons["signin.submit"]
        reveal(submit, in: app); XCTAssertTrue(submit.isHittable)
        capture(app, name: "SignIn-LargestText")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable { return }
            app.swipeDown()
        }
        for _ in 0..<10 {
            if element.isHittable { return }
            app.swipeUp()
        }
    }
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
