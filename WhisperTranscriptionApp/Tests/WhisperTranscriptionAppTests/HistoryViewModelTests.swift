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

    func testCleanupOldRecordingsClearsExpiredPathAndPreservesFavoriteAndRecentAudio() throws {
        let context = try makeModelContext()
        let directory = try makeTemporaryDirectory()
        let expiredURL = directory.appendingPathComponent("expired.m4a")
        let favoriteURL = directory.appendingPathComponent("favorite.m4a")
        let recentURL = directory.appendingPathComponent("recent.m4a")
        try Data("expired".utf8).write(to: expiredURL)
        try Data("favorite".utf8).write(to: favoriteURL)
        try Data("recent".utf8).write(to: recentURL)

        let referenceDate = Date(timeIntervalSince1970: 10 * 24 * 60 * 60)
        let expiredRecord = makeRecord(
            title: "Expired",
            text: "",
            audioFilePath: expiredURL.path,
            sourceType: .recording,
            createdAt: referenceDate.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        let favoriteRecord = makeRecord(
            title: "Favorite",
            text: "",
            audioFilePath: favoriteURL.path,
            sourceType: .recording,
            createdAt: referenceDate.addingTimeInterval(-8 * 24 * 60 * 60),
            isFavorite: true
        )
        let recentRecord = makeRecord(
            title: "Recent",
            text: "",
            audioFilePath: recentURL.path,
            sourceType: .recording,
            createdAt: referenceDate.addingTimeInterval(-6 * 24 * 60 * 60)
        )
        [expiredRecord, favoriteRecord, recentRecord].forEach(context.insert)
        try context.save()
        let viewModel = HistoryViewModel()
        viewModel.setModelContext(context)

        viewModel.cleanupOldRecordings(referenceDate: referenceDate)

        XCTAssertNil(expiredRecord.audioFilePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredURL.path))
        XCTAssertEqual(favoriteRecord.audioFilePath, favoriteURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: favoriteURL.path))
        XCTAssertEqual(recentRecord.audioFilePath, recentURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))

        let persistedRecords = try context.fetch(FetchDescriptor<TranscriptionRecord>())
        let persistedExpiredRecord = try XCTUnwrap(persistedRecords.first { $0.id == expiredRecord.id })
        XCTAssertNil(persistedExpiredRecord.audioFilePath)
    }

    func testCleanupOldRecordingsClearsMissingExpiredFileReference() throws {
        let context = try makeModelContext()
        let referenceDate = Date(timeIntervalSince1970: 10 * 24 * 60 * 60)
        let record = makeRecord(
            title: "Missing",
            text: "",
            audioFilePath: "/definitely/missing-expired-recording.m4a",
            sourceType: .recording,
            createdAt: referenceDate.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        context.insert(record)
        try context.save()
        let viewModel = HistoryViewModel()
        viewModel.setModelContext(context)

        viewModel.cleanupOldRecordings(referenceDate: referenceDate)

        XCTAssertNil(record.audioFilePath)
        XCTAssertNil(viewModel.errorMessage)
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
