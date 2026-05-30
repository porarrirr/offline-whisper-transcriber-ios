import XCTest
@testable import WhisperTranscriptionApp

final class TranscriptionRecordTests: XCTestCase {
    func testNormalizedTagsTrimDeduplicateAndPreserveFirstSpelling() {
        let tags = TranscriptionRecord.normalizedTags(from: "  Work, work, Audio、Cafe\ncafe, Research ,, ")

        XCTAssertEqual(tags, ["Work", "Audio", "Cafe", "Research"])
    }

    func testRecordStoresSegmentsAndTagsAsDecodedValues() {
        let segments = [
            TranscriptionSegment(id: 7, start: 1.25, end: 2.5, text: "first"),
            TranscriptionSegment(id: 8, start: 2.5, end: 3.75, text: "second")
        ]
        let record = TranscriptionRecord(
            title: "Interview",
            text: "first second",
            sourceType: .file,
            duration: 3.75,
            segments: segments,
            language: "en",
            tags: [" Client ", "client", "Follow-up"]
        )

        XCTAssertEqual(record.segments, segments)
        XCTAssertEqual(record.tags, ["Client", "Follow-up"])
        XCTAssertEqual(record.tagsInputText, "Client, Follow-up")
    }

    func testSearchMatchesTitleTextTagsAndTreatsBlankSearchAsMatchAll() {
        let record = TranscriptionRecord(
            title: "Planning Meeting",
            text: "Budget and launch notes",
            sourceType: .recording,
            duration: 12,
            tags: ["Client", "Roadmap"]
        )

        XCTAssertTrue(record.matchesSearchText(" planning "))
        XCTAssertTrue(record.matchesSearchText("LAUNCH"))
        XCTAssertTrue(record.matchesSearchText("roadmap"))
        XCTAssertTrue(record.matchesSearchText("  "))
        XCTAssertFalse(record.matchesSearchText("invoice"))
    }

    func testTagLookupIsCaseAndDiacriticInsensitive() {
        let record = TranscriptionRecord(
            title: "Cafe notes",
            text: "Summary",
            sourceType: .file,
            duration: 4,
            tags: ["Cafe"]
        )

        XCTAssertTrue(record.hasTag("cafe"))
        XCTAssertTrue(record.hasTag("CAFE"))
        XCTAssertFalse(record.hasTag("coffee"))
    }

    func testCorruptSegmentAndTagJSONDecodeAsEmptyCollections() {
        let record = TranscriptionRecord(
            title: "Broken import",
            text: "Text",
            sourceType: .file,
            duration: 1,
            segments: [TranscriptionSegment(id: 0, start: 0, end: 1, text: "Text")],
            tags: ["Imported"]
        )

        record.segmentsJSON = "{"
        record.tagsJSON = "{"

        XCTAssertEqual(record.segments, [])
        XCTAssertEqual(record.tags, [])
    }
}
