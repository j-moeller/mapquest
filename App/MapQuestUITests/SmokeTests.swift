import XCTest

/// Launches the app and walks through the main screens, attaching a screenshot
/// of each (run on an iPhone 13 mini simulator by .github/workflows/ui-smoke.yml).
final class SmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: seconds)
    }

    /// Answers the system's location permission alert, if it appears.
    private func allowLocation() {
        for label in ["Allow While Using App", "Allow Once", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                return
            }
        }
    }

    private func scrollTo(_ element: XCUIElement, in container: XCUIElement) {
        var attempts = 0
        while !element.isHittable && attempts < 8 {
            container.swipeUp()
            attempts += 1
        }
    }

    func testMainScreens() throws {
        // Onboarding appears while location permission is undetermined.
        if app.buttons["Allow location access"].waitForExistence(timeout: 5) {
            screenshot("00-onboarding")
            app.buttons["Allow location access"].tap()
            allowLocation()
        }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "main screen")
        pause(15) // the simulated position (Alexanderplatz) is recorded and the map zooms to it
        screenshot("01-map-2d")

        app.buttons["Line of sight"].tap()
        pause(30) // building download and ray casting
        screenshot("02-map-2d-line-of-sight")

        app.buttons["3D"].tap()
        pause(40)
        screenshot("03-map-3d")
        app.buttons["2D"].tap()

        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        screenshot("04-settings")

        let debug = app.buttons["Debug settings"]
        scrollTo(debug, in: app.collectionViews.firstMatch)
        debug.tap()
        XCTAssertTrue(app.navigationBars["Debug"].waitForExistence(timeout: 5))
        screenshot("05-debug-settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Switch to the demo explorer: imports its walks through the recorder.
        let demo = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Demo explorer'")).firstMatch
        let list = app.collectionViews.firstMatch
        var attempts = 0
        while !demo.isHittable && attempts < 8 {
            list.swipeDown()
            attempts += 1
        }
        demo.tap()
        app.buttons["Done"].tap()
        pause(120)
        app.buttons["Radius"].tap()
        pause(3)
        screenshot("06-demo-explorer")
    }
}
