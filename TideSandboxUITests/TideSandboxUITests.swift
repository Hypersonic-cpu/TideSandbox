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
        screenshot.name = "TideSandbox Main Window"
        screenshot.lifetime = .deleteOnSuccess
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
        screenshot.name = "TideSandbox 512 Grid"
        screenshot.lifetime = .deleteOnSuccess
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
        screenshot.name = "TideSandbox Bilinear Display Policy"
        screenshot.lifetime = .deleteOnSuccess
        add(screenshot)
    }

    @MainActor
    func testCompositeAnnotationsToggleAsOneOverlay() throws {
        let app = XCUIApplication()
        app.launch()

        let landLegend = app.staticTexts["Land elevation"]
        let shorelineKey = app.staticTexts["Wet sand"]
        let scaleBar = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Scale bar from 0")
        ).firstMatch
        let toggle = app.descendants(matching: .any)["map-annotations-toggle"]
        XCTAssertTrue(landLegend.waitForExistence(timeout: 8))
        XCTAssertTrue(shorelineKey.exists)
        XCTAssertTrue(scaleBar.exists)
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.click()
        XCTAssertFalse(landLegend.waitForExistence(timeout: 1))
        XCTAssertFalse(shorelineKey.exists)
        XCTAssertFalse(scaleBar.exists)
        toggle.click()
        XCTAssertTrue(landLegend.waitForExistence(timeout: 3))
        XCTAssertTrue(shorelineKey.exists)
        XCTAssertTrue(scaleBar.exists)

        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "2D Natural Composite — Legends and Scale"
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
    func test3DEditingPreviewsSharedStateAndPreservesCamera() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-fast-material-brush"]
        app.launch()

        let modePicker = app.descendants(matching: .any)["viewport-mode-picker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 8))
        let toolbar = app.descendants(matching: .any)["terrain-tool-picker"]
        let removeWater = toolbar.radioButtons.matching(
            NSPredicate(format: "label == %@", "Remove water")
        ).firstMatch
        XCTAssertTrue(removeWater.exists)
        XCTAssertTrue(toolbar.isEnabled)
        removeWater.click()

        let mode3D = modePicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "3D")
        ).firstMatch
        XCTAssertTrue(mode3D.isHittable)
        mode3D.click()
        let heightField = app.descendants(matching: .any)["height-field-3d"]
        XCTAssertTrue(heightField.waitForExistence(timeout: 3))

        let yaw = app.sliders["camera-yaw-slider"]
        let pitch = app.sliders["camera-pitch-slider"]
        XCTAssertTrue(yaw.waitForExistence(timeout: 3))
        XCTAssertTrue(pitch.exists)
        yaw.adjust(toNormalizedSliderPosition: 0.62)
        pitch.adjust(toNormalizedSliderPosition: 0.58)
        let expectedYaw = String(describing: yaw.value)
        let expectedPitch = String(describing: pitch.value)

        let time = app.descendants(matching: .any)["time-diagnostic"]
        let volume = app.descendants(matching: .any)["volume-diagnostic"]
        let wetCells = app.descendants(matching: .any)["wet-cells-diagnostic"]
        let initialTime = try XCTUnwrap(diagnosticNumber(time))
        let initialVolume = try XCTUnwrap(diagnosticNumber(volume))
        let initialWetCells = try XCTUnwrap(diagnosticNumber(wetCells))
        heightField.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.22))
            .press(forDuration: 2.2)
        XCTAssertTrue(waitForDiagnostic(volume, lessThan: initialVolume, timeout: 5))
        XCTAssertTrue(waitForDiagnostic(wetCells, lessThan: initialWetCells, timeout: 5))
        XCTAssertEqual(try XCTUnwrap(diagnosticNumber(time)), initialTime)

        let brushScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        brushScreenshot.name = "3D Remove Water — Committed Brush and Preview"
        brushScreenshot.lifetime = .keepAlways
        add(brushScreenshot)

        let polygonTool = toolbar.radioButtons.matching(
            NSPredicate(format: "label == %@", "Polygon")
        ).firstMatch
        polygonTool.click()
        for offset in [
            CGVector(dx: 0.41, dy: 0.20),
            CGVector(dx: 0.56, dy: 0.20),
            CGVector(dx: 0.56, dy: 0.29),
            CGVector(dx: 0.41, dy: 0.29),
        ] {
            heightField.coordinate(withNormalizedOffset: offset).click()
        }
        XCTAssertTrue(waitForValue("4", identifier: "polygon-vertex-count", in: app))
        let polygonScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        polygonScreenshot.name = "3D Polygon — World-Space Preview"
        polygonScreenshot.lifetime = .keepAlways
        add(polygonScreenshot)

        let volumeBeforePolygon = try XCTUnwrap(diagnosticNumber(volume))
        let apply = app.buttons["apply-polygon-button"]
        XCTAssertTrue(apply.waitForExistence(timeout: 3))
        heightField.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitForDiagnostic(volume, lessThan: volumeBeforePolygon, timeout: 5))
        XCTAssertEqual(try XCTUnwrap(diagnosticNumber(time)), initialTime)

        let committedScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        committedScreenshot.name = "3D Polygon — Committed Terrain Relief"
        committedScreenshot.lifetime = .keepAlways
        add(committedScreenshot)

        let sharedVolume = try XCTUnwrap(diagnosticText(volume))
        let mode2D = modePicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "2D")
        ).firstMatch
        XCTAssertTrue(mode2D.isHittable)
        mode2D.click()
        XCTAssertTrue(app.descendants(matching: .any)["mosaic-grid"]
            .waitForExistence(timeout: 3))
        XCTAssertEqual(try XCTUnwrap(diagnosticText(volume)), sharedVolume)

        let sharedScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        sharedScreenshot.name = "2D Composite — State Edited in 3D"
        sharedScreenshot.lifetime = .keepAlways
        add(sharedScreenshot)

        mode3D.click()
        XCTAssertTrue(heightField.waitForExistence(timeout: 3))
        XCTAssertEqual(String(describing: yaw.value), expectedYaw)
        XCTAssertEqual(String(describing: pitch.value), expectedPitch)
        XCTAssertEqual(try XCTUnwrap(diagnosticText(volume)), sharedVolume)
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

        let mosaic = app.descendants(matching: .any)["mosaic-grid"]
        let raiseTool = app.descendants(matching: .any)["terrain-tool-picker"]
            .radioButtons.matching(NSPredicate(format: "label == %@", "Add sand"))
            .firstMatch
        XCTAssertTrue(mosaic.exists)
        XCTAssertTrue(raiseTool.exists)
        raiseTool.click()
        mosaic.coordinate(withNormalizedOffset: CGVector(dx: 0.36, dy: 0.57))
            .press(forDuration: 0.8)

        let time = app.descendants(matching: .any)["time-diagnostic"]
        let volume = app.descendants(matching: .any)["volume-diagnostic"]
        let initialTime = try XCTUnwrap(diagnosticNumber(time))
        let initialVolume = try XCTUnwrap(diagnosticText(volume))

        let modePicker = app.descendants(matching: .any)["viewport-mode-picker"]
        modePicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "3D")
        ).firstMatch.click()
        let heightField = app.descendants(matching: .any)["height-field-3d"]
        let cameraPicker = app.popUpButtons["camera-preset-picker"]
        XCTAssertTrue(heightField.waitForExistence(timeout: 3))
        XCTAssertTrue(cameraPicker.waitForExistence(timeout: 3))

        let playPause = app.buttons["play-pause-button"]
        playPause.click()
        XCTAssertTrue(waitForDiagnostic(time, atLeast: initialTime + 0.6, timeout: 8))

        for title in ["Top", "Isometric", "Low oblique", "Opposite oblique"] {
            cameraPicker.click()
            let item = cameraPicker.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 2))
            item.click()
            XCTAssertTrue(heightField.exists)

            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "Moving Uneven Bed — \(title)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        playPause.click()
        XCTAssertEqual(try XCTUnwrap(diagnosticText(volume)), initialVolume)
    }

    @MainActor
    func testMovingWaterUpdatesIn3DWithYawAndPitchControls() throws {
        let app = XCUIApplication()
        app.launch()

        let mosaic = app.descendants(matching: .any)["mosaic-grid"]
        let toolPicker = app.descendants(matching: .any)["terrain-tool-picker"]
        XCTAssertTrue(mosaic.waitForExistence(timeout: 8))
        XCTAssertTrue(toolPicker.exists)
        let raiseTool = toolPicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "Add sand")
        ).firstMatch
        XCTAssertTrue(raiseTool.exists)
        raiseTool.click()
        mosaic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8)

        let volume = app.descendants(matching: .any)["volume-diagnostic"]
        let time = app.descendants(matching: .any)["time-diagnostic"]
        XCTAssertTrue(volume.waitForExistence(timeout: 3))
        XCTAssertTrue(time.exists)
        let initialVolume = try XCTUnwrap(diagnosticText(volume))
        let initialTime = try XCTUnwrap(diagnosticNumber(time))

        let modePicker = app.descendants(matching: .any)["viewport-mode-picker"]
        modePicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "3D")
        ).firstMatch.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["height-field-3d"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(toolPicker.isEnabled)

        let yaw = app.sliders["camera-yaw-slider"]
        let pitch = app.sliders["camera-pitch-slider"]
        let verticalScale = app.sliders["vertical-exaggeration-slider"]
        let opacity = app.sliders["water-opacity-slider"]
        XCTAssertTrue(yaw.waitForExistence(timeout: 3))
        XCTAssertTrue(pitch.exists)
        XCTAssertTrue(verticalScale.exists)
        XCTAssertTrue(opacity.exists)
        yaw.adjust(toNormalizedSliderPosition: 0.62)
        pitch.adjust(toNormalizedSliderPosition: 0.58)
        XCTAssertTrue(waitForValue("Custom", identifier: "camera-preset-picker", in: app))

        app.buttons["step-button"].click()
        XCTAssertTrue(waitForDiagnostic(time, greaterThan: initialTime, timeout: 5))
        let steppedTime = try XCTUnwrap(diagnosticNumber(time))
        let playPause = app.buttons["play-pause-button"]
        playPause.click()
        XCTAssertTrue(waitForDiagnostic(time, atLeast: steppedTime + 0.6, timeout: 8))
        playPause.click()
        XCTAssertEqual(try XCTUnwrap(diagnosticText(volume)), initialVolume)

        let isometricScreenshot = XCTAttachment(
            screenshot: app.windows.firstMatch.screenshot()
        )
        isometricScreenshot.name = "Moving Center Wave — Custom Yaw and Pitch"
        isometricScreenshot.lifetime = .keepAlways
        add(isometricScreenshot)

        let cameraPicker = app.popUpButtons["camera-preset-picker"]
        cameraPicker.click()
        cameraPicker.menuItems["Low oblique"].click()
        let lowObliqueScreenshot = XCTAttachment(
            screenshot: app.windows.firstMatch.screenshot()
        )
        lowObliqueScreenshot.name = "Moving Center Wave — Low oblique"
        lowObliqueScreenshot.lifetime = .keepAlways
        add(lowObliqueScreenshot)
    }

    @MainActor
    func test3DAllPresetSizesResetAndDryCoastRemainValid() throws {
        let app = XCUIApplication()
        app.launch()

        let modePicker = app.descendants(matching: .any)["viewport-mode-picker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 8))
        modePicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "3D")
        ).firstMatch.click()
        let heightField = app.descendants(matching: .any)["height-field-3d"]
        XCTAssertTrue(heightField.waitForExistence(timeout: 3))

        let presetPicker = app.popUpButtons["preset-picker"]
        let loadPreset = app.buttons["load-preset-button"]
        for (title, dimensions) in [
            ("16 × 16 Flat", "16 × 16"),
            ("32 × 32 Center Bump", "32 × 32"),
            ("128 × 128 Uneven Bed", "128 × 128"),
            ("512 × 512 Coast Channel", "512 × 512"),
        ] {
            presetPicker.click()
            presetPicker.menuItems[title].click()
            loadPreset.click()
            XCTAssertTrue(waitForValue(dimensions, identifier: "grid-diagnostic", in: app))
            XCTAssertTrue(heightField.exists)
        }

        app.buttons["reset-button"].click()
        XCTAssertTrue(waitForValue("0.000", identifier: "time-diagnostic", in: app))
        let wetCells = app.descendants(matching: .any)["wet-cells-diagnostic"]
        let wetCellCount = try XCTUnwrap(diagnosticNumber(wetCells))
        XCTAssertGreaterThan(wetCellCount, 0)
        XCTAssertLessThan(wetCellCount, Double(512 * 512))
        let depth = app.descendants(matching: .any)["depth-diagnostic"]
        let depthText = try XCTUnwrap(diagnosticText(depth)).lowercased()
        XCTAssertFalse(depthText.contains("nan"))
        XCTAssertFalse(depthText.contains("inf"))

        let cameraPicker = app.popUpButtons["camera-preset-picker"]
        cameraPicker.click()
        cameraPicker.menuItems["Opposite oblique"].click()
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "512 Coast — Dry Shoreline and Channel"
        screenshot.lifetime = .deleteOnSuccess
        add(screenshot)
    }

    @MainActor
    func test512CoastActiveFlowOrbitZoomAndFramePacing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MTL_HUD_ENABLED"] = "1"
        app.launchEnvironment["MTL_HUD_LOGGING_ENABLED"] = "1"
        app.launch()

        let presetPicker = app.popUpButtons["preset-picker"]
        let loadPreset = app.buttons["load-preset-button"]
        XCTAssertTrue(presetPicker.waitForExistence(timeout: 8))
        presetPicker.click()
        presetPicker.menuItems["512 × 512 Coast Channel"].click()
        loadPreset.click()
        XCTAssertTrue(waitForValue("512 × 512", identifier: "grid-diagnostic", in: app))

        let modePicker = app.descendants(matching: .any)["viewport-mode-picker"]
        modePicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "3D")
        ).firstMatch.click()
        let heightField = app.descendants(matching: .any)["height-field-3d"]
        XCTAssertTrue(heightField.waitForExistence(timeout: 3))

        let time = app.descendants(matching: .any)["time-diagnostic"]
        let volume = app.descendants(matching: .any)["volume-diagnostic"]
        let initialTime = try XCTUnwrap(diagnosticNumber(time))
        let initialVolume = try XCTUnwrap(diagnosticText(volume))
        let playPause = app.buttons["play-pause-button"]
        playPause.click()

        let interactionStart = ContinuousClock.now
        let orbitStart = heightField.coordinate(
            withNormalizedOffset: CGVector(dx: 0.15, dy: 0.46)
        )
        let orbitEnd = heightField.coordinate(
            withNormalizedOffset: CGVector(dx: 0.85, dy: 0.46)
        )
        let orbitDragCount = 2
        let commandedYawRadians = Float(
            heightField.frame.width * 0.70 * CGFloat(orbitDragCount)
        ) * 0.006
        XCTAssertGreaterThan(
            commandedYawRadians,
            .pi,
            "The bounded drag must exercise more than 180° of the orbit mapping"
        )
        for _ in 0..<orbitDragCount {
            orbitStart.press(forDuration: 0.15, thenDragTo: orbitEnd)
        }
        heightField.scroll(byDeltaX: 0, deltaY: -140)
        XCTAssertLessThan(
            ContinuousClock.now - interactionStart,
            .seconds(8),
            "512² orbit and shoreline zoom stopped responding to bounded UI input"
        )
        XCTAssertTrue(waitForValue("Custom", identifier: "camera-preset-picker", in: app))
        XCTAssertTrue(waitForDiagnostic(time, atLeast: initialTime + 0.8, timeout: 8))
        XCTAssertEqual(try XCTUnwrap(diagnosticText(volume)), initialVolume)

        heightField.scroll(byDeltaX: 0, deltaY: 140)
        app.buttons["fit-camera-button"].click()
        XCTAssertTrue(waitForDiagnostic(time, atLeast: initialTime + 2.2, timeout: 8))
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "512 Coast — Active Orbit and Metal Performance HUD"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        playPause.click()
        let depthText = try XCTUnwrap(diagnosticText(
            app.descendants(matching: .any)["depth-diagnostic"]
        )).lowercased()
        XCTAssertFalse(depthText.contains("nan"))
        XCTAssertFalse(depthText.contains("inf"))
        XCTAssertTrue(heightField.exists)
    }

    @MainActor
    func test3DCameraInteractionSessionAndDebugControls() throws {
        let app = XCUIApplication()
        app.launch()

        let modePicker = app.descendants(matching: .any)["viewport-mode-picker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 8))
        let mode3D = modePicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "3D")
        ).firstMatch
        let mode2D = modePicker.radioButtons.matching(
            NSPredicate(format: "label == %@", "2D")
        ).firstMatch
        mode3D.click()

        let heightField = app.descendants(matching: .any)["height-field-3d"]
        let fit = app.buttons["fit-camera-button"]
        let camera = app.popUpButtons["camera-preset-picker"]
        let yaw = app.sliders["camera-yaw-slider"]
        let pitch = app.sliders["camera-pitch-slider"]
        XCTAssertTrue(heightField.waitForExistence(timeout: 3))
        XCTAssertTrue(fit.waitForExistence(timeout: 3))
        XCTAssertTrue(camera.exists)
        XCTAssertTrue(yaw.exists)
        XCTAssertTrue(pitch.exists)
        fit.click()

        heightField.click()
        heightField.typeKey("1", modifierFlags: [])
        XCTAssertTrue(waitForValue("Top", identifier: "camera-preset-picker", in: app))

        let dragStart = heightField.coordinate(
            withNormalizedOffset: CGVector(dx: 0.32, dy: 0.42)
        )
        let dragEnd = heightField.coordinate(
            withNormalizedOffset: CGVector(dx: 0.72, dy: 0.68)
        )
        dragStart.press(forDuration: 0.15, thenDragTo: dragEnd)
        XCTAssertTrue(waitForValue("Custom", identifier: "camera-preset-picker", in: app))
        let orbitYaw = try XCTUnwrap(sliderDegrees(yaw))
        XCTAssertGreaterThan(
            orbitYaw,
            60,
            "The rightward drag should accumulate a substantial positive yaw"
        )
        XCTAssertLessThan(
            orbitYaw,
            140,
            "The rightward drag should remain near its analytical 94° mapping"
        )
        let customYaw = String(describing: yaw.value)
        let customPitch = String(describing: pitch.value)

        heightField.scroll(byDeltaX: 0, deltaY: -80)
        mode2D.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["mosaic-grid"]
                .waitForExistence(timeout: 3)
        )
        mode3D.click()
        XCTAssertTrue(heightField.waitForExistence(timeout: 3))
        XCTAssertEqual(String(describing: yaw.value), customYaw)
        XCTAssertEqual(String(describing: pitch.value), customPitch)
        XCTAssertTrue(waitForValue("Custom", identifier: "camera-preset-picker", in: app))

        XCTAssertTrue(app.menuButtons["save-scene-menu"].exists)
        let gallery = app.buttons["gallery-button"]
        gallery.click()
        let closeGallery = app.buttons["Done"]
        XCTAssertTrue(closeGallery.waitForExistence(timeout: 3))
        closeGallery.click()
        XCTAssertTrue(heightField.waitForExistence(timeout: 3))
        XCTAssertEqual(String(describing: yaw.value), customYaw)
        XCTAssertEqual(String(describing: pitch.value), customPitch)

        let debugDisclosure = app.descendants(matching: .any)["debug-3d-disclosure"]
        let inspector = app.scrollViews.firstMatch
        XCTAssertTrue(debugDisclosure.waitForExistence(timeout: 3))
        for _ in 0..<8 where !debugDisclosure.isHittable {
            inspector.scroll(byDeltaX: 0, deltaY: -80)
        }
        XCTAssertTrue(debugDisclosure.isHittable)
        debugDisclosure.click()
        let debugToggleIdentifiers = [
            "wireframe-terrain-toggle",
            "wireframe-water-toggle",
            "domain-bounds-toggle",
            "surface-normals-toggle",
            "wet-cell-mask-toggle",
            "camera-target-toggle",
        ]
        for identifier in debugToggleIdentifiers {
            let toggle = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(toggle.waitForExistence(timeout: 3))
            for _ in 0..<8 where !toggle.isHittable {
                inspector.scroll(byDeltaX: 0, deltaY: -80)
            }
            XCTAssertTrue(toggle.isHittable)
            toggle.click()
            XCTAssertEqual(toggle.value as? Int, 1)
        }

        let wetMask = app.descendants(matching: .any)["wet-cell-mask-toggle"]
        wetMask.click()
        XCTAssertEqual(wetMask.value as? Int, 0)
        XCTAssertEqual(String(describing: yaw.value), customYaw)
        XCTAssertEqual(String(describing: pitch.value), customPitch)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "3D Free Orbit — Debug Geometry"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testSavedSceneSurvivesRelaunchInGallery() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TIDESANDBOX_STORAGE_NAMESPACE"] = "PersistenceRelaunch"
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
        screenshot.name = "TideSandbox Persistent Gallery"
        screenshot.lifetime = .deleteOnSuccess
        add(screenshot)
    }

    @MainActor
    func testUnsavedChangesRequireConfirmationBeforeSceneReplacement() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TIDESANDBOX_STORAGE_NAMESPACE"] = "DirtyWarning"
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

    private func sliderDegrees(_ slider: XCUIElement) -> Double? {
        let text = String(describing: slider.value)
        let numericText = String(text.filter { "-+.0123456789".contains($0) })
        return Double(numericText)
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

    private func waitForDiagnostic(
        _ element: XCUIElement,
        greaterThan minimum: Double,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = self.diagnosticNumber(element) else {
                return false
            }
            return value > minimum
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForDiagnostic(
        _ element: XCUIElement,
        atLeast minimum: Double,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = self.diagnosticNumber(element) else {
                return false
            }
            return value >= minimum
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForDiagnostic(
        _ element: XCUIElement,
        lessThan maximum: Double,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement,
                  let value = self.diagnosticNumber(element) else {
                return false
            }
            return value < maximum
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func diagnosticNumber(_ element: XCUIElement) -> Double? {
        guard let text = diagnosticText(element) else { return nil }
        return text.split { character in
            !character.isNumber && character != "." && character != "-" && character != "+"
        }
        .compactMap { Double($0) }
        .first
    }

    private func diagnosticText(_ element: XCUIElement) -> String? {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label.isEmpty ? nil : element.label
    }
}
