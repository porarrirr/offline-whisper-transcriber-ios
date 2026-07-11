import XCTest
@testable import WhisperTranscriptionApp

final class TranscriptionSegmentTests: XCTestCase {
    func testReadableTimestampOmitsHoursBeforeOneHour() {
        let segment = TranscriptionSegment(id: 0, start: 65.432, end: 125.001, text: "hello")

        XCTAssertEqual(segment.formattedTimestamp, "[01:05 --> 02:05]")
    }

    func testReadableTimestampIncludesHoursAfterOneHour() {
        let segment = TranscriptionSegment(id: 0, start: 3_661.25, end: 7_322.5, text: "hello")

        XCTAssertEqual(segment.formattedTimestamp, "[1:01:01 --> 2:02:02]")
    }

    func testSRTTimestampIncludesMilliseconds() {
        let segment = TranscriptionSegment(id: 0, start: 3_661.25, end: 3_662.007, text: "hello")

        XCTAssertEqual(segment.srtTimestamp, "01:01:01,250 --> 01:01:02,007")
    }

    func testPlainTextJoinsJapaneseSegmentsWithoutForcedLineBreaksOrSpaces() {
        let segments = [
            TranscriptionSegment(id: 0, start: 0, end: 1, text: "照明写真"),
            TranscriptionSegment(id: 1, start: 1, end: 2, text: "5位"),
            TranscriptionSegment(id: 2, start: 2, end: 3, text: "5000円ぐらい")
        ]

        XCTAssertEqual(TranscriptionSegment.plainText(from: segments), "照明写真5位5000円ぐらい")
    }

    func testPlainTextJoinsEnglishSegmentsWithSpaces() {
        let segments = [
            TranscriptionSegment(id: 0, start: 0, end: 1, text: "Hello,"),
            TranscriptionSegment(id: 1, start: 1, end: 2, text: "world.")
        ]

        XCTAssertEqual(TranscriptionSegment.plainText(from: segments), "Hello, world.")
    }

    func testPlainTextUsesFallbackWhenSegmentsAreEmpty() {
        XCTAssertEqual(
            TranscriptionSegment.plainText(from: [], fallback: "existing\ntext"),
            "existing\ntext"
        )
    }
}

final class TranscriptionChunkProcessorTests: XCTestCase {
    func testAcceptedSegmentsRemoveRepeatedEnglishTextAcrossOverlapBoundary() {
        let previous = [
            TranscriptionSegment(id: 0, start: 295, end: 300, text: "A boundary phrase")
        ]
        let candidates = [
            TranscriptionSegment(id: 0, start: 299, end: 302, text: "boundary phrase continues"),
            TranscriptionSegment(id: 1, start: 302, end: 304, text: "afterward")
        ]

        let accepted = TranscriptionChunkProcessor.acceptedSegments(
            from: candidates,
            acceptedStart: 300,
            previousSegments: previous
        )

        XCTAssertEqual(accepted.map(\.text), ["continues", "afterward"])
        XCTAssertEqual(accepted.first?.start, 300)
        XCTAssertEqual(
            TranscriptionSegment.plainText(from: previous + accepted),
            "A boundary phrase continues afterward"
        )
    }

    func testAcceptedSegmentsDropFullyRepeatedJapaneseBoundarySegment() {
        let previous = [
            TranscriptionSegment(id: 0, start: 295, end: 300, text: "境界の文章")
        ]
        let candidates = [
            TranscriptionSegment(id: 0, start: 299, end: 301, text: "境界の文章"),
            TranscriptionSegment(id: 1, start: 301, end: 303, text: "続きです")
        ]

        let accepted = TranscriptionChunkProcessor.acceptedSegments(
            from: candidates,
            acceptedStart: 300,
            previousSegments: previous
        )

        XCTAssertEqual(accepted.map(\.text), ["続きです"])
        XCTAssertEqual(
            TranscriptionSegment.plainText(from: previous + accepted),
            "境界の文章続きです"
        )
    }

    func testAcceptedSegmentsRejectSegmentsEntirelyInsideDiscardedOverlap() {
        let candidates = [
            TranscriptionSegment(id: 0, start: 295, end: 299.9, text: "old overlap"),
            TranscriptionSegment(id: 1, start: 300, end: 302, text: "new text")
        ]

        let accepted = TranscriptionChunkProcessor.acceptedSegments(
            from: candidates,
            acceptedStart: 300,
            previousSegments: []
        )

        XCTAssertEqual(accepted.map(\.text), ["new text"])
    }
}

final class HistoryIntentLimitTests: XCTestCase {
    func testValidHistoryLimitsAreAccepted() {
        XCTAssertNoThrow(try HistoryIntentLimit.validate(1))
        XCTAssertNoThrow(try HistoryIntentLimit.validate(100))
    }

    func testInvalidHistoryLimitsThrowInsteadOfReachingCollectionPrefix() {
        XCTAssertThrowsError(try HistoryIntentLimit.validate(-1))
        XCTAssertThrowsError(try HistoryIntentLimit.validate(0))
        XCTAssertThrowsError(try HistoryIntentLimit.validate(101))
    }
}
