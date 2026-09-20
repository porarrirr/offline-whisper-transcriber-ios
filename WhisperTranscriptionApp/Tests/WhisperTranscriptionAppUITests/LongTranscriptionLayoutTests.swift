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

        let firstSegment = app.descendants(matching: .any)["transcriptParagraph-0"]
        XCTAssertTrue(scrollUntilVisible(firstSegment, in: app))
        firstSegment.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(app.links.firstMatch.exists)

        let alternative = app.buttons["transcriptionAlternative-0-0"]
        XCTAssertFalse(alternative.exists)

        firstSegment.press(forDuration: 0.7)
        app.buttons["editTranscriptSegment-0"].tap()
        XCTAssertTrue(
            app.textViews["transcriptionSegmentEditor"].waitForExistence(timeout: 10)
        )
        app.buttons
            .matching(identifier: "transcriptionSegmentEditorCancel")
            .firstMatch
            .tap()

        let marker = app.descendants(matching: .any)["transcriptParagraph-1"]
        XCTAssertTrue(scrollUntilVisible(marker, in: app))
    }

    func testPlaybackHighlightsParagraphsInBothDisplayStyles() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-long-transcription", "--ui-test-history-detail",
                               "--ui-test-inline-edit", "--ui-test-playback",
                               "-transcriptDisplayStyle", "timeline"]
        app.launch()
        let paragraph = app.otherElements["transcriptParagraph-0"]
        XCTAssertTrue(scrollUntilVisible(paragraph, in: app))
        paragraph.tap()
        XCTAssertFalse(paragraph.isSelected)
        app.buttons["historyPlayPause"].tap()
        let selected = NSPredicate(format: "selected == true")
        expectation(for: selected, evaluatedWith: paragraph)
        waitForExpectations(timeout: 5)
        let timeline = XCTAttachment(screenshot: app.screenshot())
        timeline.name = "Timeline playback highlight"
        timeline.lifetime = .keepAlways
        add(timeline)
        app.buttons["historyTranscriptDisplayToggle"].tap()
        expectation(for: selected, evaluatedWith: paragraph)
        waitForExpectations(timeout: 5)
        let reading = XCTAttachment(screenshot: app.screenshot())
        reading.name = "Reading playback highlight"
        reading.lifetime = .keepAlways
        add(reading)
    }

    func testHistoryTitleEditorOffersGenerationForExistingTitle() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Apple Intelligence title generation requires iOS 27") }

        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-long-transcription", "--ui-test-history-detail"]
        app.launch()

        XCTAssertTrue(app.otherElements["historyTranscriptionCard"].waitForExistence(timeout: 10))
        app.buttons["historyEditTitle"].tap()

        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["generateTitleFromTitleEditor"].exists)
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
