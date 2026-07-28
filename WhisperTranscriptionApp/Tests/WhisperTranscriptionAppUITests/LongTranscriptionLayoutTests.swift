import XCTest

final class LongTranscriptionLayoutTests: XCTestCase {
    func testResultLongTextScrollingAndDisplayStyleChangesRemainStable() {
        exerciseLongTranscriptionScreen(
            extraArguments: [],
            cardIdentifier: "resultTranscriptionCard",
            toggleIdentifier: "resultTranscriptDisplayToggle"
        )
    }

    func testHistoryLongTextScrollingAndTimestampChangesRemainStable() {
        exerciseLongTranscriptionScreen(
            extraArguments: ["--ui-test-history-detail"],
            cardIdentifier: "historyTranscriptionCard",
            toggleIdentifier: "historyTranscriptDisplayToggle"
        )
    }

    func testHistoryTimelineAndInlineEditingControlsAreAvailable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-long-transcription",
            "--ui-test-history-detail",
            "--ui-test-inline-edit",
            // 表示スタイルはUserDefaultsに残るので、セグメント行を前提とするテストでは固定する。
            "-transcriptDisplayStyle",
            "timeline",
        ]
        app.launch()

        XCTAssertTrue(app.otherElements["historyTranscriptionCard"].waitForExistence(timeout: 10))

        let firstSegment = app.descendants(matching: .any)["transcriptionSegment-0"]
        XCTAssertTrue(scrollUntilVisible(firstSegment, in: app))
        firstSegment.tap()

        let playbackAlert = app.alerts.firstMatch
        if playbackAlert.waitForExistence(timeout: 2) {
            playbackAlert.buttons["OK"].tap()
        }

        let alternative = app.buttons["transcriptionAlternative-0-0"]
        XCTAssertFalse(alternative.exists)

        firstSegment.press(forDuration: 0.7)
        XCTAssertTrue(
            app.textViews["transcriptionSegmentEditor"].waitForExistence(timeout: 10)
        )
        app.buttons
            .matching(identifier: "transcriptionSegmentEditorCancel")
            .firstMatch
            .tap()

        let marker = app.descendants(matching: .any)["timelineMarker-30"]
        XCTAssertTrue(scrollUntilVisible(marker, in: app))
    }

    private func exerciseLongTranscriptionScreen(
        extraArguments: [String],
        cardIdentifier: String,
        toggleIdentifier: String?
    ) {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-long-transcription",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
            // 前回の実行で保存された表示スタイルに依存しないよう既定に固定する。
            "-transcriptDisplayStyle",
            "timeline",
        ] + extraArguments
        app.launch()

        XCTAssertTrue(app.otherElements[cardIdentifier].waitForExistence(timeout: 10))

        for _ in 0..<12 {
            app.swipeUp(velocity: .fast)
        }
        for _ in 0..<12 {
            app.swipeDown(velocity: .fast)
        }

        if let toggleIdentifier {
            let toggle = app.buttons[toggleIdentifier]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            for _ in 0..<20 {
                toggle.tap()
            }
        }

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.otherElements[cardIdentifier].exists)
    }

    private func scrollUntilVisible(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int = 8
    ) -> Bool {
        if element.exists && element.isHittable {
            return true
        }

        for _ in 0..<maximumSwipes {
            app.swipeUp()
            if element.exists && element.isHittable {
                return true
            }
        }
        return false
    }
}
