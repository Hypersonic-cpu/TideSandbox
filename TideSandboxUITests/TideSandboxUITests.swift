import XCTest

final class TideSandboxUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchAndCoreSimulationControls() throws {
        let app = XCUIApplication()
        app.launch()

        let playPause = app.buttons["play-pause-button"]
        let step = app.buttons["step-button"]
        let reset = app.buttons["reset-button"]
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(playPause.waitForExistence(timeout: 3))
        XCTAssertTrue(step.exists)
        XCTAssertTrue(reset.exists)

        playPause.click()
        XCTAssertEqual(playPause.label, "Pause")
        playPause.click()
        XCTAssertEqual(playPause.label, "Play")
        step.click()
        reset.click()

        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Water Sandbox Main Window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testAllBuiltInPresetsLoad() throws {
        let app = XCUIApplication()
        app.launch()

        let picker = app.popUpButtons["preset-picker"]
        let load = app.buttons["load-preset-button"]
        let gridDiagnostic = app.descendants(matching: .any)["grid-diagnostic"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertTrue(load.exists)
        XCTAssertTrue(gridDiagnostic.waitForExistence(timeout: 3))

        let presets = [
            ("16 × 16 Flat", "16 × 16"),
            ("32 × 32 Center Bump", "32 × 32"),
            ("128 × 128 Uneven Bed", "128 × 128"),
            ("512 × 512 Coast Channel", "512 × 512"),
        ]
        for (title, dimensions) in presets {
            picker.click()
            let menuItem = app.menuItems[title]
            XCTAssertTrue(menuItem.waitForExistence(timeout: 2))
            menuItem.click()
            load.click()

            let updated = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", dimensions),
                object: gridDiagnostic
            )
            XCTAssertEqual(
                XCTWaiter().wait(for: [updated], timeout: 8),
                .completed,
                "\(title) did not publish its grid dimensions"
            )
        }

        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Water Sandbox 512 Grid"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
