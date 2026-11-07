import XCTest

/// Launches the app and walks through the main screens, attaching a screenshot
/// of each (run on an iPhone 13 mini simulator by .github/workflows/ui-smoke.yml).
final class SmokeTests: XCTestCase {
    private var app: XCUIApplication!

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

    func testMainScreens() throws {
        // Onboarding appears only while location permission is undetermined.
        if app.buttons["Not now"].waitForExistence(timeout: 3) {
            screenshot("00-onboarding")
            app.buttons["Not now"].tap()
        }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "main screen")
        pause(10) // let the simulated position be recorded
        screenshot("01-map-2d")

        app.buttons["Line of sight"].tap()
        pause(15) // building download and ray casting
        screenshot("02-map-2d-line-of-sight")

        app.buttons["3D"].tap()
        pause(20)
        screenshot("03-map-3d")
        app.buttons["2D"].tap()

        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        screenshot("04-settings")

        app.buttons["Debug settings"].tap()
        XCTAssertTrue(app.navigationBars["Debug"].waitForExistence(timeout: 5))
        screenshot("05-debug-settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Switch to the demo explorer: imports its walks through the recorder.
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Demo explorer'")).firstMatch.tap()
        app.buttons["Done"].tap()
        pause(90)
        app.buttons["Radius"].tap()
        pause(3)
        screenshot("06-demo-explorer")
    }
}
