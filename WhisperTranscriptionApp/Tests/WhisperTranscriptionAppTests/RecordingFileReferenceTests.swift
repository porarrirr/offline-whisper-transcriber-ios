import Foundation
import XCTest
@testable import WhisperTranscriptionApp

final class RecordingFileReferenceTests: XCTestCase {
    func testStoredPathResolvesInsideCurrentRecordingsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingFileReferenceTests-\(UUID().uuidString)")
            .appendingPathComponent("Recordings", isDirectory: true)
        let audioURL = directory.appendingPathComponent("imported-test.m4a")

        let storedPath = try RecordingFileReference.storedPath(
            for: audioURL,
            recordingsDirectory: directory
        )
        let resolvedURL = try RecordingFileReference.fileURL(
            for: storedPath,
            recordingsDirectory: directory
        )

        XCTAssertEqual(storedPath, "Recordings/imported-test.m4a")
        XCTAssertEqual(resolvedURL, audioURL.standardizedFileURL)
    }

    func testStoredPathResolvesAfterContainerDirectoryChanges() throws {
        let oldDirectory = URL(fileURLWithPath: "/old/container/Documents/Recordings")
        let newDirectory = URL(fileURLWithPath: "/new/container/Documents/Recordings")
        let storedPath = try RecordingFileReference.storedPath(
            for: oldDirectory.appendingPathComponent("imported-test.m4a"),
            recordingsDirectory: oldDirectory
        )

        let resolvedURL = try RecordingFileReference.fileURL(
            for: storedPath,
            recordingsDirectory: newDirectory
        )

        XCTAssertEqual(
            resolvedURL,
            newDirectory.appendingPathComponent("imported-test.m4a").standardizedFileURL
        )
    }

    func testStoredPathRejectsDirectoryTraversal() {
        XCTAssertThrowsError(
            try RecordingFileReference.fileURL(
                for: "Recordings/../outside.m4a",
                recordingsDirectory: URL(fileURLWithPath: "/container/Documents/Recordings")
            )
        )
    }
}
