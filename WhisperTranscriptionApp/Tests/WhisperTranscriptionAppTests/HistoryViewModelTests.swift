import AVFoundation
import Foundation
import SwiftData
import XCTest
@testable import WhisperTranscriptionApp

@MainActor
final class HistoryViewModelTests: XCTestCase {
    func testTitleGenerationFailureDoesNotSetHistoryWideError() async throws {
        let context = try makeModelContext()
        let record = makeRecord(title: "Original", text: "transcript")
        context.insert(record)
        try context.save()
        let viewModel = HistoryViewModel(titleGenerator: { _ in
            throw TitleGenerationTestError.safeguard
        })
        viewModel.setModelContext(context)

        let message = await viewModel.generateTitleWithAppleIntelligence(record)

        XCTAssertEqual(message, TitleGenerationTestError.safeguard.localizedDescription)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(record.title, "Original")
    }

    func testSuccessfulTitleGenerationUpdatesTitleWithoutHistoryWideError() async throws {
        let context = try makeModelContext()
        let record = makeRecord(title: "Original", text: "transcript")
        context.insert(record)
        try context.save()
        let viewModel = HistoryViewModel(titleGenerator: { _ in "Generated" })
        viewModel.setModelContext(context)

        let message = await viewModel.generateTitleWithAppleIntelligence(record)

        XCTAssertNil(message)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(record.title, "Generated")
    }

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
        XCTAssertEqual(viewModel.suggestedTags, ["Archive", "Client", "Work"])

        viewModel.searchText = " alpha "
        viewModel.fetchRecords()
        XCTAssertEqual(viewModel.records.map(\.id), [oldRecord.id])
        XCTAssertTrue(viewModel.suggestedTags.isEmpty)

        viewModel.searchText = ""
        viewModel.toggleTagFilter("client")
        XCTAssertEqual(viewModel.records.map(\.id), [newestRecord.id])

        viewModel.filterFavorite = true
        viewModel.fetchRecords()
        XCTAssertEqual(viewModel.records.map(\.id), [newestRecord.id])

        viewModel.clearTagFilter()
        XCTAssertEqual(viewModel.records.map(\.id), [newestRecord.id])
    }

    func testTagSuggestionsFollowSearchTextAndSelectingOneAppliesTagFilter() throws {
        let context = try makeModelContext()
        let matchingRecord = makeRecord(title: "Match", text: "body", tags: ["Café", "Client"])
        let otherRecord = makeRecord(title: "Other", text: "body", tags: ["Archive"])
        [matchingRecord, otherRecord].forEach(context.insert)
        try context.save()

        let viewModel = HistoryViewModel()
        viewModel.setModelContext(context)

        viewModel.searchText = " cafe "
        XCTAssertEqual(viewModel.suggestedTags, ["Café"])

        viewModel.selectTagSuggestion("Café")

        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertEqual(viewModel.selectedTagTokens.map(\.name), ["Café"])
        XCTAssertEqual(viewModel.suggestedTags, ["Archive", "Client"])
        XCTAssertEqual(viewModel.records.map(\.id), [matchingRecord.id])
    }

    func testMultipleTagFiltersUseIntersectionAndCombineWithTextSearch() throws {
        let context = try makeModelContext()
        let matchingRecord = makeRecord(
            title: "Weekly sync",
            text: "田中さんが次の対応を説明しました",
            tags: ["会議", "重要"]
        )
        let wrongTextRecord = makeRecord(
            title: "Planning",
            text: "鈴木さんが担当します",
            tags: ["会議", "重要"]
        )
        let missingTagRecord = makeRecord(
            title: "One-on-one",
            text: "田中さんとの面談記録",
            tags: ["会議"]
        )
        [matchingRecord, wrongTextRecord, missingTagRecord].forEach(context.insert)
        try context.save()

        let viewModel = HistoryViewModel()
        viewModel.setModelContext(context)

        viewModel.selectTagSuggestion("会議")
        viewModel.selectTagSuggestion("重要")

        XCTAssertEqual(viewModel.selectedTagTokens.map(\.name), ["会議", "重要"])
        XCTAssertEqual(Set(viewModel.records.map(\.id)), Set([matchingRecord.id, wrongTextRecord.id]))

        viewModel.searchText = "田中"
        viewModel.fetchRecords()

        XCTAssertEqual(viewModel.records.map(\.id), [matchingRecord.id])
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

    func testDeleteRecordKeepsAudioAndAllowsRestoreWithinThirtyDays() throws {
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

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(viewModel.records.isEmpty)
        let remainingRecords = try context.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(remainingRecords.count, 1)
        XCTAssertNotNil(remainingRecords[0].deletedAt)
        XCTAssertEqual(viewModel.recentlyDeletedRecords.map(\.id), [record.id])

        viewModel.restoreRecord(record)
        XCTAssertNil(record.deletedAt)
        XCTAssertEqual(viewModel.records.map(\.id), [record.id])
    }

    func testDeleteRecordDoesNotMoveAudio() throws {
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

        XCTAssertTrue(viewModel.deleteRecord(record))

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(viewModel.records.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        let remainingRecords = try context.fetch(FetchDescriptor<TranscriptionRecord>())
        XCTAssertEqual(remainingRecords.map(\.id), [record.id])
    }

    func testRestoreRejectsExpiredDeletion() throws {
        let context = try makeModelContext()
        let record = makeRecord(title: "Expired", text: "Body")
        record.deletedAt = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        context.insert(record)
        try context.save()
        let viewModel = HistoryViewModel()
        viewModel.setModelContext(context)

        viewModel.restoreRecord(record)

        XCTAssertNotNil(record.deletedAt)
        XCTAssertTrue(viewModel.records.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testExpiredLocalOnlyHistoryIsPurgedWithoutDeletingCloudTombstones() throws {
        let context = try makeModelContext()
        let directory = try makeTemporaryDirectory()
        let localAudio = directory.appendingPathComponent("local.m4a")
        let cloudAudio = directory.appendingPathComponent("cloud.m4a")
        try Data("local audio".utf8).write(to: localAudio)
        try Data("cloud audio".utf8).write(to: cloudAudio)
        let deletedAt = Date().addingTimeInterval(-31 * 24 * 60 * 60)

        let local = makeRecord(title: "Local", text: "Local body", audioFilePath: localAudio.path)
        local.deletedAt = deletedAt
        let cloud = makeRecord(title: "Cloud", text: "Cloud body", audioFilePath: cloudAudio.path)
        cloud.lastSyncedSnapshotJSON = CloudHistorySnapshot(cloud).json
        cloud.deletedAt = deletedAt
        [local, cloud].forEach(context.insert)
        try context.save()

        let viewModel = HistoryViewModel(recordingsDirectory: directory)
        viewModel.setModelContext(context)
        XCTAssertTrue(viewModel.purgeExpiredLocalOnlyRecords())

        XCTAssertFalse(FileManager.default.fileExists(atPath: localAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudAudio.path))
        XCTAssertEqual(try context.fetch(FetchDescriptor<TranscriptionRecord>()).map(\.id), [cloud.id])
        XCTAssertEqual(viewModel.recentlyDeletedRecords.map(\.id), [cloud.id])
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

private enum TitleGenerationTestError: LocalizedError {
    case safeguard

    var errorDescription: String? {
        "The model's safety guardrails were triggered."
    }
}

private final class FailingMoveFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
