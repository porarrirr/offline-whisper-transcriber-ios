import Foundation
import SwiftData
import XCTest
@testable import WhisperTranscriptionApp

@MainActor
final class HistoryViewModelTests: XCTestCase {
    func testFetchRecordsBuildsAvailableTagsAndAppliesFilters() throws {
        let context = try makeModelContext()
        let oldRecord = makeRecord(
            title: "Old planning",
            text: "alpha notes",
            createdAt: Date(timeIntervalSince1970: 100),
            tags: ["Work"]
        )
        let middleRecord = makeRecord(
            title: "Archive",
            text: "misc",
            createdAt: Date(timeIntervalSince1970: 150),
            tags: ["Archive"]
        )
        let newestRecord = makeRecord(
            title: "Launch",
            text: "beta release",
            createdAt: Date(timeIntervalSince1970: 200),
            isFavorite: true,
            tags: ["Client", "Work"]
        )
        [oldRecord, middleRecord, newestRecord].forEach(context.insert)
        try context.save()

        let viewModel = HistoryViewModel()
        viewModel.setModelContext(context)

        XCTAssertEqual(viewModel.records.map(\.id), [newestRecord.id, middleRecord.id, oldRecord.id])
        XCTAssertEqual(viewModel.availableTags, ["Archive", "Client", "Work"])

        viewModel.searchText = " alpha "
        viewModel.fetchRecords()
        XCTAssertEqual(viewModel.records.map(\.id), [oldRecord.id])

        viewModel.searchText = ""
        viewModel.toggleTagFilter("client")
        XCTAssertEqual(viewModel.records.map(\.id), [newestRecord.id])

        viewModel.filterFavorite = true
        viewModel.fetchRecords()
        XCTAssertEqual(viewModel.records.map(\.id), [newestRecord.id])

        viewModel.clearTagFilter()
        XCTAssertEqual(viewModel.records.map(\.id), [newestRecord.id])
    }

    func testUpdateTagsNormalizesInputAndRefreshesAvailableTags() throws {
        let context = try makeModelContext()
        let record = makeRecord(title: "Tags", text: "body")
        context.insert(record)
        try context.save()
        let viewModel = HistoryViewModel()
        viewModel.setModelContext(context)

        viewModel.updateTags(record, tagsInput: "  Client, client、Follow-up\n ")

        XCTAssertEqual(record.tags, ["Client", "Follow-up"])
        XCTAssertEqual(viewModel.availableTags, ["Client", "Follow-up"])
    }

    func testDeleteRecordRemovesSwiftDataRecordAndAssociatedAudioFile() throws {
        let context = try makeModelContext()
        let directory = try makeTemporaryDirectory()
        let audioURL = directory.appendingPathComponent("recording.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let record = makeRecord(
            title: "Recording",
            text: "",
            audioFilePath: audioURL.path,
            sourceType: .recording
        )
        context.insert(record)
        try context.save()
        let viewModel = HistoryViewModel()
        viewModel.setModelContext(context)

        viewModel.deleteRecord(record)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(viewModel.records.isEmpty)
        let remainingRecords = try context.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertTrue(remainingRecords.isEmpty)
    }

    private func makeModelContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TranscriptionRecord.self, configurations: configuration)
        return ModelContext(container)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeRecord(
        title: String,
        text: String,
        audioFilePath: String? = nil,
        sourceType: TranscriptionRecord.SourceType = .file,
        createdAt: Date = Date(timeIntervalSince1970: 100),
        isFavorite: Bool = false,
        tags: [String] = []
    ) -> TranscriptionRecord {
        TranscriptionRecord(
            title: title,
            text: text,
            sourceType: sourceType,
            audioFilePath: audioFilePath,
            duration: 1,
            createdAt: createdAt,
            isFavorite: isFavorite,
            tags: tags
        )
    }
}
