import AVFoundation
import Foundation
import SwiftData
import XCTest
@testable import WhisperTranscriptionApp

@MainActor
final class HistoryViewModelTests: XCTestCase {
    func testRecoverySkipsActiveRecordingAndImportsItOnlyOnceAfterStop() throws {
        let context = try makeModelContext()
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("active.caf")
        try makeRecoverableRecording(at: url, duration: 1.25)
        let viewModel = HistoryViewModel(recordingsDirectory: directory)
        viewModel.setModelContext(context)

        viewModel.importUntrackedRecordings(excluding: url)
        viewModel.importUntrackedRecordings(excluding: url)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TranscriptionRecord>()), 0)

        viewModel.importUntrackedRecordings()
        viewModel.importUntrackedRecordings()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TranscriptionRecord>()), 1)
        XCTAssertEqual(
            try XCTUnwrap(context.fetch(FetchDescriptor<TranscriptionRecord>()).first).duration,
            1.25,
            accuracy: 0.01
        )
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRecoveryDoesNotCreateZeroDurationHistoryForUnreadableM4A() throws {
        let context = try makeModelContext()
        let directory = try makeTemporaryDirectory()
        try Data("unfinished m4a".utf8).write(
            to: directory.appendingPathComponent("recording-killed-before-finalization.m4a")
        )
        let viewModel = HistoryViewModel(recordingsDirectory: directory)
        viewModel.setModelContext(context)

        viewModel.importUntrackedRecordings()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TranscriptionRecord>()), 0)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRecoveryDoesNotDuplicateTrackedCAFWhenFinalizedM4AAlsoExists() async throws {
        let context = try makeModelContext()
        let directory = try makeTemporaryDirectory()
        let cafURL = directory.appendingPathComponent("finalization-interrupted.caf")
        try makeRecoverableRecording(at: cafURL, duration: 1.25)
        let m4aURL = try await RecordingAudioFinalizer.finalize(cafURL, removeSource: false)
        let record = makeRecord(
            title: "Already saved",
            text: "",
            audioFilePath: cafURL.path,
            sourceType: .recording
        )
        context.insert(record)
        try context.save()
        let viewModel = HistoryViewModel(recordingsDirectory: directory)
        viewModel.setModelContext(context)

        viewModel.importUntrackedRecordings()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TranscriptionRecord>()), 1)
        XCTAssertEqual(record.audioFilePath, cafURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cafURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4aURL.path))
        XCTAssertNil(viewModel.errorMessage)
    }

    func testSavingRecoveredRecordingReusesHistoryAcrossRepeatedStops() throws {
        let context = try makeModelContext()
        let path = "Recordings/recovered-\(UUID().uuidString).m4a"
        let url = try RecordingFileReference.fileURL(for: path)
        let record = makeRecord(title: "Keep title", text: "Keep transcript", audioFilePath: path)
        context.insert(record)
        try context.save()
        let viewModel = TranscribeViewModel()

        for _ in 0..<3 {
            let saved = try viewModel.saveRecordingRecord(url: url, duration: 5896, modelContext: context)
            XCTAssertEqual(saved.id, record.id)
        }

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TranscriptionRecord>()), 1)
        XCTAssertEqual(record.duration, 5896)
        XCTAssertEqual(record.title, "Keep title")
        XCTAssertEqual(record.text, "Keep transcript")
    }

    func testNewRecordingRemainsSingleHistoryItemOnRepeatedSave() throws {
        let context = try makeModelContext()
        let url = try RecordingFileReference.fileURL(for: "Recordings/new-\(UUID().uuidString).m4a")
        let viewModel = TranscribeViewModel()
        let first = try viewModel.saveRecordingRecord(url: url, duration: 12, modelContext: context)
        let second = try viewModel.saveRecordingRecord(url: url, duration: 12, modelContext: context)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TranscriptionRecord>()), 1)
    }

    func testSavingRecordingReusesLegacyAbsoluteReference() throws {
        let context = try makeModelContext()
        let name = "legacy-\(UUID().uuidString).m4a"
        let record = makeRecord(title: "Recovered", text: "", audioFilePath: "/old/container/Documents/Recordings/\(name)")
        context.insert(record)
        try context.save()
        let url = try RecordingFileReference.fileURL(for: "Recordings/\(name)")

        let saved = try TranscribeViewModel().saveRecordingRecord(url: url, duration: 10, modelContext: context)

        XCTAssertEqual(saved.id, record.id)
        XCTAssertEqual(saved.audioFilePath, "Recordings/\(name)")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TranscriptionRecord>()), 1)
    }

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

    func testUpdateSegmentTextPersistsSegmentsAlternativesAndRebuiltText() throws {
        let context = try makeModelContext()
        let record = TranscriptionRecord(
            title: "Editable",
            text: "誤認識です",
            sourceType: .recording,
            duration: 2,
            segments: [
                TranscriptionSegment(
                    id: 0,
                    start: 0,
                    end: 1,
                    text: "誤認識",
                    alternatives: ["誤認識", "正しい認識"]
                ),
                TranscriptionSegment(id: 1, start: 1, end: 2, text: "です"),
            ],
            language: "ja"
        )
        context.insert(record)
        try context.save()
        let viewModel = HistoryViewModel()
        viewModel.setModelContext(context)

        XCTAssertTrue(
            viewModel.updateSegmentText(
                record,
                segmentID: 0,
                text: "正しい認識"
            )
        )

        XCTAssertEqual(record.text, "正しい認識です")
        XCTAssertEqual(record.segments[0].text, "正しい認識")
        XCTAssertEqual(record.segments[0].alternatives, ["誤認識", "正しい認識"])
        let persisted = try XCTUnwrap(
            context.fetch(FetchDescriptor<TranscriptionRecord>()).first
        )
        XCTAssertEqual(persisted.text, "正しい認識です")
        XCTAssertEqual(persisted.segments[0].text, "正しい認識")
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

    func testDeleteRecordKeepsHistoryWhenAudioCannotBeStagedForDeletion() throws {
        let context = try makeModelContext()
        let directory = try makeTemporaryDirectory()
        let audioURL = directory.appendingPathComponent("recording.m4a")
        try Data("audio".utf8).write(to: audioURL)
        let record = makeRecord(
            title: "Recording",
            text: "saved transcript",
            audioFilePath: audioURL.path,
            sourceType: .recording
        )
        context.insert(record)
        try context.save()
        let viewModel = HistoryViewModel(fileManager: FailingMoveFileManager())
        viewModel.setModelContext(context)

        XCTAssertFalse(viewModel.deleteRecord(record))

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(viewModel.records.map(\.id), [record.id])
        XCTAssertNotNil(viewModel.errorMessage)
        let remainingRecords = try context.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(remainingRecords.map(\.id), [record.id])
    }

    func testStartupRecoveryRestoresStagedAudioWhenHistoryStillReferencesOriginalPath() throws {
        let context = try makeModelContext()
        let directory = try makeTemporaryDirectory()
        let originalURL = directory.appendingPathComponent("recording.m4a")
        let stagedURL = directory.appendingPathComponent(".deleting-test--recording.m4a")
        try Data("audio".utf8).write(to: stagedURL)
        let record = makeRecord(
            title: "Recording",
            text: "saved transcript",
            audioFilePath: originalURL.path,
            sourceType: .recording
        )
        context.insert(record)
        try context.save()
        let viewModel = HistoryViewModel(recordingsDirectory: directory)
        viewModel.setModelContext(context)

        viewModel.importUntrackedRecordings()

        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertNil(viewModel.errorMessage)
        let remainingRecords = try context.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(remainingRecords.map(\.id), [record.id])
    }

    func testStartupMigratesLegacyContainerPathWithoutCreatingDuplicateHistory() throws {
        let context = try makeModelContext()
        let directory = try makeTemporaryDirectory()
        let fileName = "imported-\(UUID().uuidString).m4a"
        let currentURL = directory.appendingPathComponent(fileName)
        try Data("audio".utf8).write(to: currentURL)
        let legacyPath = "/old/container/Documents/Recordings/\(fileName)"
        let record = makeRecord(
            title: "Imported transcription",
            text: "saved transcript",
            audioFilePath: legacyPath,
            sourceType: .file
        )
        context.insert(record)
        try context.save()
        let viewModel = HistoryViewModel(recordingsDirectory: directory)
        viewModel.setModelContext(context)

        viewModel.importUntrackedRecordings()

        XCTAssertEqual(record.audioFilePath, "Recordings/\(fileName)")
        let remainingRecords = try context.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(remainingRecords.map(\.id), [record.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))
        XCTAssertNil(viewModel.errorMessage)
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

    private func makeRecoverableRecording(at url: URL, duration: TimeInterval) throws {
        let sampleRate = 48_000.0
        let settings = AudioRecorder.recordingFileSettings(sampleRate: sampleRate)
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        try file?.write(from: buffer)
        file = nil
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

private final class FailingMoveFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
