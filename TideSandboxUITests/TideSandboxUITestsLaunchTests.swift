//
//  TideSandboxUITestsLaunchTests.swift
//  TideSandboxUITests
//
//  Created by kong on 31-07-2026.
//

import XCTest

final class TideSandboxUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Water Sandbox Launch"
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }
}
