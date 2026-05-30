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
}
