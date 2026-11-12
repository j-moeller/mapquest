import XCTest

/// Launches the app and walks through the main screens, attaching a screenshot
/// of each (run it on an iPhone 13 mini simulator: Xcode › Product › Test).
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

    /// A row of the open menu, by the start of its label ("Map view, 2D · Fog · All time").
    private func menuRow(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// Opens the menu and one of its pages.
    private func openMenu(_ title: String) {
        app.buttons["Menu"].tap()
        let row = menuRow(title)
        if row.waitForExistence(timeout: 5) { row.tap() }
    }

    /// Changes the map view (2D/3D, fog or heatmap, layer, time span) from the menu.
    private func mapView(_ change: () -> Void) {
        openMenu("Map view")
        XCTAssertTrue(app.navigationBars["Map view"].waitForExistence(timeout: 5), "map view settings")
        change()
        app.buttons["Done"].tap()
    }

    func testMainScreens() throws {
        // Onboarding appears while location permission is undetermined.
        if app.buttons["Allow location access"].waitForExistence(timeout: 5) {
            screenshot("00-onboarding")
            app.buttons["Allow location access"].tap()
            allowLocation()
        }
        let menu = app.buttons["Menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "main screen")
        pause(15) // the simulated position (Alexanderplatz) is recorded and the map zooms to it
        screenshot("01-map-2d")
        // The fog must cover newly exposed map at once (no unfogged flash when zooming out).
        let map = app.maps.firstMatch
        if map.exists {
            map.pinch(withScale: 0.2, velocity: -3)
            screenshot("01b-zoomed-out-immediately")
            pause(3)
            screenshot("01c-zoomed-out")
            map.pinch(withScale: 5, velocity: 3)
            pause(2)
        }

        mapView { app.buttons["Line of sight"].tap() }
        pause(30) // building download and ray casting
        screenshot("02-map-2d-line-of-sight")

        mapView { app.buttons["3D"].tap() }
        pause(40)
        screenshot("03-map-3d")
        mapView { app.buttons["2D"].tap() }

        menu.tap()
        XCTAssertTrue(app.navigationBars["Menu"].waitForExistence(timeout: 5))
        screenshot("04-menu")
        menuRow("Building data").tap()
        XCTAssertTrue(app.switches["Download automatically"].waitForExistence(timeout: 5))
        screenshot("04b-building-data")
        app.navigationBars.buttons.element(boundBy: 0).tap() // back to the menu

        // Switch to the demo explorer: imports its walks through the recorder.
        menuRow("Data source").tap()
        let demo = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Demo explorer'")).firstMatch
        if demo.waitForExistence(timeout: 5) { demo.tap() }
        app.buttons["Done"].tap()
        pause(120) // the demo track (113 000 fixes at 1 Hz, sampled) is imported through the recorder
        mapView { app.buttons["Radius"].tap() }
        pause(3)
        screenshot("06-demo-explorer")
        if map.exists {
            map.pinch(withScale: 0.2, velocity: -3)
            screenshot("07-demo-zoomed-out-immediately")
            pause(2)
        }

        // The debug panel over the map: sliders and a usable map at the same time.
        menu.tap()
        let debugButton = menuRow("Debug settings")
        if debugButton.waitForExistence(timeout: 5) {
            if map.exists { map.pinch(withScale: 4, velocity: 3) }
            debugButton.tap()
            XCTAssertTrue(app.navigationBars["Debug"].waitForExistence(timeout: 5), "debug panel")
            screenshot("07b-debug-panel")
            // Half-transparent fog, so the blur under it and the soft edges show from here on.
            let opacity = app.sliders["Fog opacity"]
            if opacity.waitForExistence(timeout: 3) {
                opacity.adjust(toNormalizedSliderPosition: (0.5 - 0.1) / 0.9)
            }
            // The map above the panel still pans.
            if map.exists {
                map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                    .press(forDuration: 0.05, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.35)))
            }
            pause(2)
            screenshot("07c-debug-panel-map-panned")
            app.navigationBars["Debug"].buttons["Done"].tap()
            pause(1)
        }

        // Time-based view: October 2026 (commutes, walks, a day in Braunschweig).
        if map.exists { map.pinch(withScale: 4, velocity: 3) } // back to street scale around the walks
        mapView {
            app.buttons["Month"].tap()
            let previous = app.buttons["Previous month"]
            if previous.waitForExistence(timeout: 5) { previous.tap() }
        }
        pause(25)
        screenshot("08-month-fog")

        // Heatmap of the same month.
        mapView { app.buttons["Heatmap"].tap() }
        pause(10)
        screenshot("09-month-heatmap")
        if map.exists {
            map.pinch(withScale: 3, velocity: 3)
            pause(6)
            screenshot("10-heatmap-zoomed-in")
        }

        // The statistics, and all bundled cities (Berlin, Braunschweig, Peine) in the districts list.
        openMenu("Statistics")
        XCTAssertTrue(app.navigationBars["Statistics"].waitForExistence(timeout: 5))
        screenshot("11-statistics")
        let districts = app.buttons["Cities and districts"]
        if districts.waitForExistence(timeout: 5) {
            districts.tap()
            pause(8)
            screenshot("12-districts")
        }
    }
}
