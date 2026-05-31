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
