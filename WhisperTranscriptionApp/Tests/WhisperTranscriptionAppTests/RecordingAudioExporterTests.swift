import Foundation
import XCTest
@testable import WhisperTranscriptionApp

final class RecordingAudioExporterTests: XCTestCase {
    func testExportCopiesRecordingAndSanitizesInvalidTitleCharacters() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.caf")
        let sourceData = Data("audio bytes".utf8)
        try sourceData.write(to: sourceURL)
        let recordID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let record = TranscriptionRecord(
            id: recordID,
            title: " /Meeting:*?\"<>|\nNotes\r ",
            text: "",
            sourceType: .recording,
            audioFilePath: sourceURL.path,
            duration: 1
        )

        let exportedURL = try XCTUnwrap(RecordingAudioExporter.export(record: record))
        addTeardownBlock { try? FileManager.default.removeItem(at: exportedURL) }

        XCTAssertEqual(try Data(contentsOf: exportedURL), sourceData)
        XCTAssertTrue(exportedURL.lastPathComponent.hasPrefix("Meeting_Notes_\(recordID.uuidString.prefix(8))."))
        XCTAssertEqual(exportedURL.pathExtension, "caf")
        XCTAssertFalse(exportedURL.lastPathComponent.contains("/"))
        XCTAssertFalse(exportedURL.lastPathComponent.contains("\n"))
    }

    func testExportReturnsNilWhenAudioFileIsMissing() {
        let record = TranscriptionRecord(
            title: "Missing",
            text: "",
            sourceType: .recording,
            audioFilePath: "/definitely/missing.m4a",
            duration: 1
        )

        XCTAssertNil(RecordingAudioExporter.export(record: record))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperRecordingExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
