import XCTest

final class TellerFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testBundledSampleOpensPlayerWithoutServer() {
        let app = XCUIApplication()
        app.launchEnvironment["TELLER_API_BASE_URL"] = "http://127.0.0.1:1"
        app.launch()

        waitFor(app.buttons["play-sample"]).tap()
        waitFor(app.buttons["player-close"])
        XCTAssertTrue(app.buttons["player-play-toggle"].exists)
        XCTAssertTrue(app.buttons["transcript-line-0"].exists)
        app.buttons["player-close"].tap()
        XCTAssertTrue(app.buttons["mini-play-toggle"].exists)
    }

    @MainActor
    func testGuestImportsTextUnlocksAndReopensFromLibrary() {
        let app = XCUIApplication()
        let title = "Rain on the platform " + UUID().uuidString.prefix(6)
        let story = [
            title,
            "Ada watched the lights across the tracks.",
            "\"The train is early,\" Ada said.",
            "\"Then we have time,\" Noah replied.",
            "The platform clock began to ring."
        ].joined(separator: "\n")
        app.launch()

        waitFor(app.buttons["source-paste"]).tap()
        let editor = waitFor(app.textViews["story-text"])
        editor.tap()
        editor.typeText(story)
        let submit = waitFor(app.buttons["create-preview"])
        app.swipeUp()
        submit.tap()

        waitFor(app.buttons["player-close"], timeout: 25)
        XCTAssertEqual(app.staticTexts["player-title"].label, String(title))
        let unlock = waitFor(app.buttons["continue-book"])
        if !unlock.isHittable { app.swipeUp() }
        unlock.tap()
        let playerClosed = NSPredicate(format: "exists == false")
        expectation(for: playerClosed, evaluatedWith: unlock)
        waitForExpectations(timeout: 15)
        app.buttons["player-close"].tap()

        app.terminate()
        app.launch()
        waitFor(app.tabBars.buttons["Library"]).tap()
        let row = waitFor(app.buttons.containing(.staticText, identifier: String(title)).firstMatch, timeout: 20)
        row.tap()
        waitFor(app.buttons["player-close"])
        XCTAssertEqual(app.staticTexts["player-title"].label, String(title))
        XCTAssertFalse(app.buttons["continue-book"].exists)
    }

    @discardableResult
    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Missing UI element: \(element)", file: file, line: line)
        return element
    }
}
