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

    @MainActor
    func testEveryDisplayResolutionPolicyRendersWithoutChangingGrid() throws {
        let app = XCUIApplication()
        app.launch()

        let picker = app.popUpButtons["resolution-policy-picker"]
        let gridDiagnostic = app.descendants(matching: .any)["grid-diagnostic"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        XCTAssertTrue(gridDiagnostic.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("32 × 32", identifier: "grid-diagnostic", in: app))

        for title in ["Nearest cell", "Bilinear scalar", "Area average", "Identical cells"] {
            picker.click()
            let item = app.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 2))
            item.click()
            XCTAssertTrue(app.windows.firstMatch.exists)
            XCTAssertTrue(waitForValue("32 × 32", identifier: "grid-diagnostic", in: app))
        }

        picker.click()
        app.menuItems["Bilinear scalar"].click()
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Water Sandbox Bilinear Display Policy"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testViewportSwitchPreserves2DStateAndReturnsToMosaic() throws {
        let app = XCUIApplication()
        app.launch()

        let modePicker = app.descendants(matching: .any)["viewport-mode-picker"]
        let mosaic = app.descendants(matching: .any)["mosaic-grid"]
        let heightField = app.descendants(matching: .any)["height-field-3d"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 8))
        XCTAssertTrue(mosaic.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForValue("32 × 32", identifier: "grid-diagnostic", in: app))

        modePicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "3D")
        ).firstMatch.click()
        XCTAssertTrue(heightField.waitForExistence(timeout: 3))
        XCTAssertFalse(mosaic.exists)
        XCTAssertTrue(waitForValue("32 × 32", identifier: "grid-diagnostic", in: app))

        modePicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "2D")
        ).firstMatch.click()
        XCTAssertTrue(mosaic.waitForExistence(timeout: 3))
        XCTAssertFalse(heightField.exists)
        XCTAssertTrue(waitForValue("32 × 32", identifier: "grid-diagnostic", in: app))
    }

    @MainActor
    func test3DMetalViewportSmoke() throws {
        let app = XCUIApplication()
        app.launch()

        let modePicker = app.descendants(matching: .any)["viewport-mode-picker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 8))
        modePicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "3D")
        ).firstMatch.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["height-field-3d"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.windows.firstMatch.exists)

        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "3D Metal Terrain"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func test3DTerrainAcrossDeterministicCameraPresets() throws {
        let app = XCUIApplication()
        app.launch()

        let presetPicker = app.popUpButtons["preset-picker"]
        let loadPreset = app.buttons["load-preset-button"]
        XCTAssertTrue(presetPicker.waitForExistence(timeout: 8))
        presetPicker.click()
        app.menuItems["128 × 128 Uneven Bed"].click()
        loadPreset.click()
        XCTAssertTrue(waitForValue("128 × 128", identifier: "grid-diagnostic", in: app))

        let modePicker = app.descendants(matching: .any)["viewport-mode-picker"]
        modePicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "3D")
        ).firstMatch.click()
        let heightField = app.descendants(matching: .any)["height-field-3d"]
        let cameraPicker = app.popUpButtons["camera-preset-picker"]
        XCTAssertTrue(heightField.waitForExistence(timeout: 3))
        XCTAssertTrue(cameraPicker.waitForExistence(timeout: 3))

        for title in ["Top", "Isometric", "Low oblique", "Opposite oblique"] {
            cameraPicker.click()
            let item = cameraPicker.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 2))
            item.click()
            XCTAssertTrue(heightField.exists)

            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "Uneven Bed — \(title)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testSavedSceneSurvivesRelaunchInGallery() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WATER_SANDBOX_STORAGE_NAMESPACE"] = "PersistenceRelaunch"
        app.launchArguments = ["--reset-scene-storage"]
        app.launch()

        let gallery = app.buttons["gallery-button"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 8))
        gallery.click()
        XCTAssertTrue(waitForGalleryCount("4", in: app))
        let flatCard = app.buttons[
            "scene-card-10000000-0000-4000-8000-000000000016"
        ]
        XCTAssertTrue(flatCard.waitForExistence(timeout: 3))
        flatCard.click()
        app.buttons["open-scene-button"].click()
        XCTAssertTrue(waitForValue("16 × 16", identifier: "grid-diagnostic", in: app))

        app.buttons["step-button"].click()
        let saveMenu = app.menuButtons["save-scene-menu"]
        XCTAssertTrue(saveMenu.waitForExistence(timeout: 3))
        saveMenu.click()
        let saveItem = app.menuItems["Save"]
        XCTAssertTrue(saveItem.waitForExistence(timeout: 2))
        saveItem.click()

        gallery.click()
        XCTAssertTrue(waitForGalleryCount("5", in: app))
        app.buttons["Done"].click()
        app.terminate()

        app.launchArguments = []
        app.launch()
        XCTAssertTrue(gallery.waitForExistence(timeout: 8))
        gallery.click()
        XCTAssertTrue(waitForGalleryCount("5", in: app))

        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Water Sandbox Persistent Gallery"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testUnsavedChangesRequireConfirmationBeforeSceneReplacement() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WATER_SANDBOX_STORAGE_NAMESPACE"] = "DirtyWarning"
        app.launchArguments = ["--reset-scene-storage"]
        app.launch()

        let step = app.buttons["step-button"]
        let load = app.buttons["load-preset-button"]
        XCTAssertTrue(step.waitForExistence(timeout: 8))
        step.click()
        load.click()

        let warning = app.staticTexts["Discard unsaved changes?"]
        XCTAssertTrue(warning.waitForExistence(timeout: 3))
        let cancel = app.sheets.firstMatch.buttons["Cancel"]
        XCTAssertTrue(cancel.exists)
        cancel.click()
        XCTAssertFalse(warning.exists)
        XCTAssertTrue(waitForValue("32 × 32", identifier: "grid-diagnostic", in: app))
    }

    private func waitForGalleryCount(_ count: String, in app: XCUIApplication) -> Bool {
        waitForValue(count, identifier: "gallery-count", in: app)
    }

    private func waitForValue(
        _ value: String,
        identifier: String,
        in app: XCUIApplication
    ) -> Bool {
        let element = app.descendants(matching: .any)[identifier]
        guard element.waitForExistence(timeout: 8) else { return false }
        let predicate = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", value, value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 8) == .completed
    }
}
