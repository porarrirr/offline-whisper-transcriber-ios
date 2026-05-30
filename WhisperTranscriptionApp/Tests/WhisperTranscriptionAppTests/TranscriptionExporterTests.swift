import Foundation
import XCTest
@testable import WhisperTranscriptionApp

final class TranscriptionExporterTests: XCTestCase {
    func testTXTExportUsesSegmentsWhenTimestampsAreAvailable() throws {
        let record = makeRecord(
            text: "full text",
            segments: [
                TranscriptionSegment(id: 0, start: 0, end: 1.25, text: "hello"),
                TranscriptionSegment(id: 1, start: 1.25, end: 2.5, text: "world")
            ]
        )

        let url = try XCTUnwrap(TranscriptionExporter.export(record: record, format: .txt))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(content.contains("Session"))
        XCTAssertTrue(content.contains("Language: en"))
        XCTAssertTrue(content.contains("--- With Timestamps ---"))
        XCTAssertTrue(content.contains("[00:00 --> 00:01] hello"))
        XCTAssertTrue(content.contains("[00:01 --> 00:02] world"))
    }

    func testCSVExportEscapesQuotesAndUsesFallbackRowWithoutSegments() throws {
        let record = makeRecord(text: "He said \"hello\", then left", duration: 12.5, segments: [])

        let url = try XCTUnwrap(TranscriptionExporter.export(record: record, format: .csv))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(
            content,
            "id,start,end,text\n0,0,12.5,\"He said \"\"hello\"\", then left\"\n"
        )
    }

    func testSRTExportNumbersSegmentsByExportOrderAndFormatsMilliseconds() throws {
        let record = makeRecord(
            segments: [
                TranscriptionSegment(id: 10, start: 0, end: 1.25, text: "hello"),
                TranscriptionSegment(id: 99, start: 61.5, end: 62.007, text: "world")
            ]
        )

        let url = try XCTUnwrap(TranscriptionExporter.export(record: record, format: .srt))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(
            content,
            "1\n00:00:00,000 --> 00:00:01,250\nhello\n\n2\n00:01:01,500 --> 00:01:02,007\nworld\n\n"
        )
    }

    func testJSONExportContainsMachineReadableMetadataAndSegments() throws {
        let segments = [
            TranscriptionSegment(id: 0, start: 0.5, end: 1.25, text: "hello")
        ]
        let record = makeRecord(text: "hello", duration: 1.25, segments: segments)

        let url = try XCTUnwrap(TranscriptionExporter.export(record: record, format: .json))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exportedSegments = try XCTUnwrap(object["segments"] as? [[String: Any]])

        XCTAssertEqual(object["title"] as? String, "Session")
        XCTAssertEqual(object["text"] as? String, "hello")
        XCTAssertEqual(object["language"] as? String, "en")
        XCTAssertEqual(object["duration"] as? Double, 1.25)
        XCTAssertEqual(exportedSegments.count, 1)
        XCTAssertEqual(exportedSegments[0]["id"] as? Int, 0)
        XCTAssertEqual(exportedSegments[0]["start"] as? Double, 0.5)
        XCTAssertEqual(exportedSegments[0]["end"] as? Double, 1.25)
        XCTAssertEqual(exportedSegments[0]["text"] as? String, "hello")
    }

    private func makeRecord(
        id: UUID = UUID(uuidString: "12345678-1234-1234-1234-1234567890ab")!,
        title: String = "Session",
        text: String = "hello world",
        duration: Double = 2.5,
        segments: [TranscriptionSegment],
        language: String? = "en"
    ) -> TranscriptionRecord {
        TranscriptionRecord(
            id: id,
            title: title,
            text: text,
            sourceType: .file,
            duration: duration,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            segments: segments,
            language: language
        )
    }
}
