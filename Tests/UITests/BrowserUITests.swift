import XCTest

@MainActor
final class BrowserUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testLaunchAdaptiveLayoutAndNativeSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let files = app.descendants(matching: .any)["fileList"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 15), "File browser did not appear")
        XCTAssertTrue(app.buttons["moreActions"].isHittable)

        if app.windows.firstMatch.frame.width >= 720 {
            let preview = app.descendants(matching: .any)["previewPane"].firstMatch
            XCTAssertTrue(preview.exists, "Wide windows must show a preview")
            XCTAssertLessThanOrEqual(preview.frame.maxX, files.frame.minX + 2,
                "Wide layout must place preview left and files right")
            XCTAssertGreaterThan(preview.frame.width, 100)
            XCTAssertGreaterThan(files.frame.width, 100)
        }
        attachScreenshot("Browser")

        app.buttons["moreActions"].tap()
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let expected = (Bundle(for: Self.self).bundleIdentifier ?? "").contains(".sideload.") ? "Sideload" : "App Store"
        XCTAssertTrue(app.staticTexts[expected].exists, "Settings must show the compiled edition")
        attachScreenshot("Settings")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["moreActions"].waitForExistence(timeout: 5))
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
