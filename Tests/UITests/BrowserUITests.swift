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
        attachScreenshot("Settings")
        let expected = (Bundle(for: Self.self).bundleIdentifier ?? "").contains(".sideload.") ? "Sideload" : "App Store"
        let edition = app.descendants(matching: .any)["buildEdition"].firstMatch
        XCTAssertTrue(edition.waitForExistence(timeout: 5))
        XCTAssertEqual(edition.value as? String, expected, "Settings must expose the compiled edition")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["moreActions"].waitForExistence(timeout: 5))
    }

    func testDocumentPickerCancellationReturnsToBrowser() throws {
        let app = launchBrowser()
        for _ in 0..<2 {
            app.buttons["importFiles"].tap()
            let picker = app.descendants(matching: .any)["documentPicker"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 15))
            tapPickerButton("Cancel", in: app)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: picker)], timeout: 15), .completed)
            XCTAssertTrue(app.buttons["importFiles"].isHittable)
            XCTAssertFalse(app.descendants(matching: .any)["taskProgress"].firstMatch.exists)
        }
    }

    func testLargeLocalSevenZipPickerHandoffAndImport() throws {
        let app = launchBrowser()
        app.buttons["importFiles"].tap()
        let picker = app.descendants(matching: .any)["documentPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        tapPickerItem("Picker Fixtures", in: app)
        tapPickerItem("iArchiver-CI-5GiB", in: app)
        attachScreenshot("LargeArchiveSelected")
        tapPickerButton("Open", in: app)

        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: picker)], timeout: 15), .completed,
            "Selecting a local 5 GiB 7z must close the picker before the app copies it")
        let summary = app.descendants(matching: .any)["archiveSummary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 180),
            "The real 5 GiB sandbox import and archive-directory read must finish")
        XCTAssertTrue(app.buttons["Picker ready.txt"].waitForExistence(timeout: 5),
            "The archive engine must read the 7z header beyond the 4 GiB boundary")
        attachScreenshot("LargeArchiveOpened")
    }

    private func launchBrowser() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["importFiles"].waitForExistence(timeout: 15))
        return app
    }

    private func tapPickerButton(_ name: String, in app: XCUIApplication) {
        // The provider's remote view can take time to start on a cold simulator.
        // Query a typed control from the app, without repeatedly enumerating
        // every descendant beneath a remote accessibility element in a waiter.
        let button = app.navigationBars.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 120), "Picker button \(name) did not appear")
        button.tap()
    }

    private func tapPickerItem(_ name: String, in app: XCUIApplication) {
        let cell = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 120), "Picker item \(name) did not appear")
        cell.tap()
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            attachScreenshot("Failure")
            let hierarchy = XCTAttachment(string: XCUIApplication().debugDescription)
            hierarchy.name = "Accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
