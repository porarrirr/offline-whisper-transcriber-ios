import XCTest

final class LongTranscriptionLayoutTests: XCTestCase {
    func testResultLongTextScrollingAndTimestampChangesRemainStable() {
        exerciseLongTranscriptionScreen(
            extraArguments: [],
            cardIdentifier: "resultTranscriptionCard",
            toggleIdentifier: "resultTimestampToggle"
        )
    }

    func testHistoryLongTextScrollingAndTimestampChangesRemainStable() {
        exerciseLongTranscriptionScreen(
            extraArguments: ["--ui-test-history-detail"],
            cardIdentifier: "historyTranscriptionCard",
            toggleIdentifier: "historyTimestampToggle"
        )
    }

    private func exerciseLongTranscriptionScreen(
        extraArguments: [String],
        cardIdentifier: String,
        toggleIdentifier: String
    ) {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-long-transcription",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ] + extraArguments
        app.launch()

        XCTAssertTrue(app.otherElements[cardIdentifier].waitForExistence(timeout: 10))

        for _ in 0..<12 {
            app.swipeUp(velocity: .fast)
        }
        for _ in 0..<12 {
            app.swipeDown(velocity: .fast)
        }

        let toggle = app.buttons[toggleIdentifier]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        for _ in 0..<20 {
            toggle.tap()
        }

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.otherElements[cardIdentifier].exists)
    }
}
