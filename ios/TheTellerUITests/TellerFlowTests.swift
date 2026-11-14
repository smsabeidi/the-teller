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
        let speed = waitFor(app.buttons["player-speed"])
        speed.tap()
        waitFor(app.buttons["1.5×"]).tap()
        XCTAssertEqual(speed.value as? String, "1.5×")
        app.buttons["player-close"].tap()
        XCTAssertTrue(app.buttons["mini-play-toggle"].exists)
    }

    @MainActor
    func testGuestImportsTextUnlocksAndReopensFromLibrary() {
        let app = XCUIApplication()
        app.launchEnvironment["TELLER_API_BASE_URL"] = "http://127.0.0.1:8000"
        let title = "Rain on the platform " + UUID().uuidString.prefix(6)
        let story = [
            title,
            "Chapter One",
            "Ada watched the lights across the tracks.",
            "\"The train is early,\" Ada said.",
            "Chapter Two",
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
        let transport = app.buttons["player-play-toggle"]
        if transport.label == "Pause" { transport.tap() }
        waitFor(app.buttons["player-chapters"]).tap()
        waitFor(app.buttons["player-chapter-5"]).tap()
        let savedPosition = waitFor(app.buttons["player-position"]).label
        XCTAssertEqual(savedPosition, "Line 6 of 9")
        app.buttons["player-close"].tap()

        app.terminate()
        app.launch()
        waitFor(app.tabBars.buttons["Library"]).tap()
        let row = waitFor(app.buttons["library-continue"], timeout: 20)
        row.tap()
        waitFor(app.buttons["player-close"])
        XCTAssertEqual(app.staticTexts["player-title"].label, String(title))
        XCTAssertFalse(app.buttons["continue-book"].exists)
        XCTAssertEqual(waitFor(app.buttons["player-position"]).label, savedPosition)
    }

    @MainActor
    func testDiscoverShowsFeaturedAndSearchResults() {
        let app = XCUIApplication()
        app.launchEnvironment["TELLER_API_BASE_URL"] = "http://127.0.0.1:8000"
        app.launch()

        waitFor(app.tabBars.buttons["Discover"]).tap()
        waitFor(app.buttons["discover-book-1342"])
        let search = waitFor(app.textFields["discover-search"])
        search.tap()
        search.typeText("Frankenstein")
        if app.keyboards.buttons["Search"].exists { app.keyboards.buttons["Search"].tap() }
        waitFor(app.buttons["discover-book-84"])
        XCTAssertFalse(app.buttons["discover-book-1342"].exists)

        waitFor(app.buttons["discover-human"]).tap()
        waitFor(app.textFields["human-audio-query"])
        XCTAssertTrue(app.buttons["human-audio-search"].exists)
    }

    @discardableResult
    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Missing UI element: \(element)", file: file, line: line)
        return element
    }
}
