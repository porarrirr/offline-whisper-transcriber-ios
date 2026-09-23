import AVFoundation
import Foundation
import SwiftData
import UIKit

struct HistoryTagToken: Identifiable, Hashable {
    let name: String

    var id: String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

@MainActor
class HistoryViewModel: ObservableObject {
    typealias TitleGenerator = (String) async throws -> String

    @Published var records: [TranscriptionRecord] = []
    @Published private(set) var recentlyDeletedRecords: [TranscriptionRecord] = []
    @Published var searchText = ""
    @Published var filterFavorite = false
    @Published var selectedTagTokens: [HistoryTagToken] = []
    @Published private(set) var availableTags: [String] = []
    @Published var errorMessage: String?

    var suggestedTags: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let foldedQuery = Self.foldedTagText(query)
        return availableTags.filter { tag in
            !selectedTagTokens.contains(where: { Self.tagsAreEqual($0.name, tag) }) &&
                (foldedQuery.isEmpty || Self.foldedTagText(tag).contains(foldedQuery))
        }
    }
    
    private var modelContext: ModelContext?
    private var fetchTask: Task<Void, Never>?
    private var availableTagsNeedRefresh = true
    private let fileManager: FileManager
    private let recordingsDirectoryOverride: URL?
    private let titleGenerator: TitleGenerator

    init(
        fileManager: FileManager = .default,
        recordingsDirectory: URL? = nil,
        titleGenerator: @escaping TitleGenerator = { text in
            try await AppleIntelligenceService.shared.suggestedTitle(for: text)
        }
    ) {
        self.fileManager = fileManager
        self.recordingsDirectoryOverride = recordingsDirectory
        self.titleGenerator = titleGenerator
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        availableTagsNeedRefresh = true
        fetchRecords()
    }
    
    func fetchRecords() {
        fetchTask?.cancel()
        performFetchRecords()
    }

    private func performFetchRecords() {
        guard let modelContext = modelContext else { return }
        
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: historyPredicate,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        do {
            var allRecords = try modelContext.fetch(descriptor)
            allRecords.removeAll { $0.deletedAt != nil }
            recentlyDeletedRecords = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )).filter { $0.deletedAt != nil }
            refreshAvailableTagsIfNeeded(modelContext: modelContext)
            
            if !searchText.isEmpty {
                allRecords = allRecords.filter { $0.matchesSearchText(searchText) }
            }

            if !selectedTagTokens.isEmpty {
                allRecords = allRecords.filter { record in
                    selectedTagTokens.allSatisfy { record.hasTag($0.name) }
                }
            }
            
            records = allRecords
        } catch {
            setError(String(localized: "Failed to load history") + ": \(error.localizedDescription)")
        }
    }

    func scheduleFetchRecords() {
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.performFetchRecords()
        }
    }

    func record(withID id: UUID) -> TranscriptionRecord? {
        guard let modelContext else { return nil }
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate<TranscriptionRecord> { record in
                record.id == id
            }
        )
        return try? modelContext.fetch(descriptor).first(where: { $0.deletedAt == nil })
    }
    
    @discardableResult
    func deleteRecord(_ record: TranscriptionRecord) -> Bool {
        deleteRecords([record])
    }

    @discardableResult
    func deleteRecords(_ recordsToDelete: [TranscriptionRecord]) -> Bool {
        guard let modelContext = modelContext else { return false }
        let deletedRecordIDs = recordsToDelete.map(\.id)
        let now = Date()
        recordsToDelete.forEach { $0.deletedAt = now; $0.modifiedAt = now }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            setError(String(localized: "Failed to delete history") + ": \(error.localizedDescription)")
            fetchRecords()
            return false
        }

        TranscriptionSpotlightSync.delete(identifiers: deletedRecordIDs)
        availableTagsNeedRefresh = true
        fetchRecords()
        HistoryCloudSync.shared.scheduleSync()
        return true
    }

    func restoreRecord(_ record: TranscriptionRecord) {
        guard let deletedAt = record.deletedAt,
              deletedAt.addingTimeInterval(30 * 24 * 60 * 60) > Date() else {
            setError("The 30-day restore period has expired.")
            return
        }
        record.deletedAt = nil
        record.modifiedAt = Date()
        do {
            guard let modelContext else { throw HistoryViewModelError.historyStoreUnavailable }
            try modelContext.save()
            TranscriptionSpotlightSync.index(record)
            availableTagsNeedRefresh = true
            fetchRecords()
            HistoryCloudSync.shared.scheduleSync()
        } catch {
            modelContext?.rollback()
            setError(error.localizedDescription)
        }
    }

    @discardableResult
    func purgeExpiredLocalOnlyRecords(asOf now: Date = Date()) -> Bool {
        guard let modelContext else { return false }
        do {
            let allRecords = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())
            let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
            let expired = allRecords.filter { record in
                guard let deletedAt = record.deletedAt, deletedAt <= cutoff else { return false }
                return record.lastSyncedSnapshotJSON == nil
                    && record.cloudRecordSystemFields == nil
                    && record.cloudAudioID == nil
                    && record.pendingAudioID == nil
            }
            guard !expired.isEmpty else { return false }

            let expiredIDs = Set(expired.map(\.id))
            let retainedURLs = try Set(allRecords.filter { !expiredIDs.contains($0.id) }
                .compactMap { record -> URL? in
                    guard let path = record.audioFilePath else { return nil }
                    return try RecordingFileReference.fileURL(
                        for: path, recordingsDirectory: recordingsDirectoryOverride)
                })
            var pathsToDelete: [String] = []
            for path in Set(expired.compactMap(\.audioFilePath)) {
                let url = try RecordingFileReference.fileURL(
                    for: path, recordingsDirectory: recordingsDirectoryOverride)
                if !retainedURLs.contains(url) { pathsToDelete.append(path) }
            }
            let stagedFiles = try stageRecordingFilesForDeletion(at: pathsToDelete)
            expired.forEach(modelContext.delete)
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                if let restoreError = restoreStagedRecordingFiles(stagedFiles) {
                    setError(HistoryViewModelError.deletionRollbackFailed(
                        databaseError: error.localizedDescription,
                        restoreError: restoreError.localizedDescription
                    ).localizedDescription)
                } else {
                    setError(String(localized: "Failed to delete expired history") + ": \(error.localizedDescription)")
                }
                return false
            }
            removeStagedRecordingFiles(stagedFiles)
            availableTagsNeedRefresh = true
            fetchRecords()
            NotificationCenter.default.post(name: HistoryCloudSync.historyChanged, object: nil)
            return true
        } catch {
            setError(String(localized: "Failed to delete expired history") + ": \(error.localizedDescription)")
            return false
        }
    }

    func updateTags(_ record: TranscriptionRecord, tagsInput: String) {
        updateTags(record, tags: TranscriptionRecord.normalizedTags(from: tagsInput))
    }

    func updateTags(_ record: TranscriptionRecord, tags: [String]) {
        let previousTagsJSON = record.tagsJSON
        record.updateTags(tags)
        do {
            try modelContext?.save()
            TranscriptionSpotlightSync.index(record)
            HistoryCloudSync.shared.scheduleSync()
        } catch {
            record.tagsJSON = previousTagsJSON
            setError(String(localized: "Failed to update tags") + ": \(error.localizedDescription)")
        }
        availableTagsNeedRefresh = true
        fetchRecords()
    }

    func toggleTagFilter(_ tag: String) {
        if let index = selectedTagTokens.firstIndex(where: { Self.tagsAreEqual($0.name, tag) }) {
            selectedTagTokens.remove(at: index)
        } else {
            selectedTagTokens.append(HistoryTagToken(name: tag))
        }
        fetchRecords()
    }

    func selectTagSuggestion(_ tag: String) {
        searchText = ""
        if !selectedTagTokens.contains(where: { Self.tagsAreEqual($0.name, tag) }) {
            selectedTagTokens.append(HistoryTagToken(name: tag))
        }
        fetchRecords()
    }

    func clearTagFilter() {
        selectedTagTokens.removeAll()
        fetchRecords()
    }
    
    func toggleFavorite(_ record: TranscriptionRecord) {
        record.isFavorite.toggle()
        record.modifiedAt = Date()
        do {
            try modelContext?.save()
            TranscriptionSpotlightSync.index(record)
            HistoryCloudSync.shared.scheduleSync()
        } catch {
            record.isFavorite.toggle()
            setError(String(localized: "Failed to update favorite status") + ": \(error.localizedDescription)")
        }
        fetchRecords()
    }

    func updateTitle(_ record: TranscriptionRecord, title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousTitle = record.title
        record.title = trimmedTitle.isEmpty ? TranscriptionRecord.defaultTitle(for: record.createdAt) : trimmedTitle
        record.modifiedAt = Date()
        do {
            try modelContext?.save()
            TranscriptionSpotlightSync.index(record)
            HistoryCloudSync.shared.scheduleSync()
        } catch {
            record.title = previousTitle
            setError(String(localized: "Failed to update title") + ": \(error.localizedDescription)")
        }
        fetchRecords()
    }

    /// Returns a message for the invoking screen to present locally. Title generation is
    /// optional, so its failure must not become a history-wide error banner.
    func generateTitleWithAppleIntelligence(_ record: TranscriptionRecord) async -> String? {
        do {
            let title = try await titleGenerator(record.text)
            updateTitle(record, title: title)
            return nil
        } catch {
            AppLogger.error(
                "Apple Intelligence title generation failed",
                context: "HistoryViewModel",
                error: error
            )
            return error.localizedDescription
        }
    }

    @discardableResult
    func updateSegmentText(
        _ record: TranscriptionRecord,
        segmentID: Int,
        text: String
    ) -> Bool {
        guard let modelContext else {
            setError(String(localized: "History store is unavailable."))
            return false
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            setError(String(localized: "Transcription text cannot be empty."))
            return false
        }

        var updatedSegments = record.segments
        guard let index = updatedSegments.firstIndex(where: { $0.id == segmentID }) else {
            setError(String(localized: "The selected transcription segment could not be found."))
            return false
        }

        let previousText = record.text
        let previousSegmentsJSON = record.segmentsJSON
        updatedSegments[index] = updatedSegments[index].replacingText(with: trimmedText)

        do {
            let data = try JSONEncoder().encode(updatedSegments)
            guard let encodedSegments = String(data: data, encoding: .utf8) else {
                throw HistoryViewModelError.segmentEncodingFailed
            }
            record.segmentsJSON = encodedSegments
            record.text = TranscriptionSegment.plainText(from: updatedSegments, fallback: previousText)
            record.modifiedAt = Date()
            try modelContext.save()
            TranscriptionSpotlightSync.index(record)
            HistoryCloudSync.shared.scheduleSync()
            errorMessage = nil
            return true
        } catch {
            record.text = previousText
            record.segmentsJSON = previousSegmentsJSON
            setError(String(localized: "Failed to update transcription") + ": \(error.localizedDescription)")
            return false
        }
    }
    
    func exportRecord(
        _ record: TranscriptionRecord,
        format: ExportFormat,
        includeTimestamps: Bool = true
    ) -> URL? {
        return TranscriptionExporter.export(
            record: record,
            format: format,
            includeTimestamps: includeTimestamps
        )
    }

    func exportRecordingAudio(_ record: TranscriptionRecord) -> URL? {
        RecordingAudioExporter.export(record: record)
    }
    
    func importUntrackedRecordings(excluding activeRecordingURL: URL? = nil) {
        guard let modelContext = modelContext else { return }

        do {
            let recordingsDirectory = try recordingsDirectory()
            let descriptor = FetchDescriptor<TranscriptionRecord>()
            let records = try modelContext.fetch(descriptor)
            var recordsChanged = try migrateLegacyAudioFilePaths(
                in: records,
                recordingsDirectory: recordingsDirectory
            )
            for record in records where record.audioFinalizationPending {
                guard let path = record.audioFilePath,
                      let url = try? RecordingFileReference.fileURL(for: path,
                          recordingsDirectory: recordingsDirectory),
                      url.standardizedFileURL != activeRecordingURL?.standardizedFileURL else { continue }
                record.audioFinalizationPending = false
                recordsChanged = true
            }
            if try repairMissingRecordingDurations(
                in: records,
                recordingsDirectory: recordingsDirectory
            ) {
                recordsChanged = true
            }
            if recordsChanged {
                try modelContext.save()
            }

            guard fileManager.fileExists(atPath: recordingsDirectory.path) else { return }

            let trackedAudioPaths = try Set(records.compactMap { record -> String? in
                guard let storedPath = record.audioFilePath else { return nil }
                return try RecordingFileReference.fileURL(
                    for: storedPath,
                    recordingsDirectory: recordingsDirectory
                ).path
            })
            let trackedRecordingBaseNames = Set(trackedAudioPaths.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            })
            let directoryURLs = try fileManager.contentsOfDirectory(
                at: recordingsDirectory,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: []
            )
            try recoverStagedRecordingDeletions(
                directoryURLs: directoryURLs,
                trackedAudioPaths: trackedAudioPaths
            )
            let supportedExtensions = Set(["caf", "m4a"])
            let recordingURLs = directoryURLs.filter {
                !$0.lastPathComponent.hasPrefix(".")
                    && supportedExtensions.contains($0.pathExtension.lowercased())
            }
            let recoverableRecordings = try recoverableRecordingURLs(from: recordingURLs)

            var importedRecords = 0
            for (url, duration) in recoverableRecordings {
                guard url.standardizedFileURL != activeRecordingURL?.standardizedFileURL,
                      !trackedAudioPaths.contains(url.standardizedFileURL.path),
                      !trackedRecordingBaseNames.contains(url.deletingPathExtension().lastPathComponent) else {
                    continue
                }
                let resourceValues = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                guard (resourceValues.fileSize ?? 0) > 0 else { continue }
                let createdAt = resourceValues.creationDate ?? Date()
                let record = TranscriptionRecord(
                    title: TranscriptionRecord.defaultTitle(for: createdAt),
                    text: "",
                    sourceType: .recording,
                    audioFilePath: try RecordingFileReference.storedPath(
                        for: url,
                        recordingsDirectory: recordingsDirectory
                    ),
                    duration: duration,
                    createdAt: createdAt
                )
                modelContext.insert(record)
                importedRecords += 1
            }

            guard importedRecords > 0 else { return }
            try modelContext.save()
            availableTagsNeedRefresh = true
            fetchRecords()
            HistoryCloudSync.shared.scheduleSync()
        } catch {
            setError(String(localized: "Failed to recover saved recordings") + ": \(error.localizedDescription)")
        }
    }

    private var historyPredicate: Predicate<TranscriptionRecord>? {
        guard filterFavorite else { return nil }
        return #Predicate<TranscriptionRecord> { record in
            record.isFavorite
        }
    }

    private func refreshAvailableTagsIfNeeded(modelContext: ModelContext) {
        guard availableTagsNeedRefresh else { return }
        do {
            let descriptor = FetchDescriptor<TranscriptionRecord>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let allRecords = try modelContext.fetch(descriptor)
            availableTags = Self.sortedUniqueTags(from: allRecords.filter { $0.deletedAt == nil })
            selectedTagTokens.removeAll { selectedTag in
                !availableTags.contains(where: { Self.tagsAreEqual($0, selectedTag.name) })
            }
            availableTagsNeedRefresh = false
        } catch {
            setError(String(localized: "Failed to load tags") + ": \(error.localizedDescription)")
        }
    }

    private func setError(_ message: String) {
        errorMessage = message
        AppLogger.error(message, context: "HistoryViewModel")
    }

    private func stageRecordingFilesForDeletion(at paths: [String]) throws -> [StagedRecordingDeletion] {
        var stagedFiles: [StagedRecordingDeletion] = []
        do {
            for path in paths {
                let sourceURL = try RecordingFileReference.fileURL(
                    for: path,
                    recordingsDirectory: recordingsDirectoryOverride
                )
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                let stagedURL = sourceURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(".deleting-\(UUID().uuidString)--\(sourceURL.lastPathComponent)")
                try fileManager.moveItem(at: sourceURL, to: stagedURL)
                stagedFiles.append(StagedRecordingDeletion(originalURL: sourceURL, stagedURL: stagedURL))
            }
            return stagedFiles
        } catch {
            if let restoreError = restoreStagedRecordingFiles(stagedFiles) {
                throw HistoryViewModelError.deletionRollbackFailed(
                    databaseError: error.localizedDescription,
                    restoreError: restoreError.localizedDescription
                )
            }
            throw error
        }
    }

    private func restoreStagedRecordingFiles(_ stagedFiles: [StagedRecordingDeletion]) -> Error? {
        var firstError: Error?
        for stagedFile in stagedFiles.reversed() where fileManager.fileExists(atPath: stagedFile.stagedURL.path) {
            do {
                try fileManager.moveItem(at: stagedFile.stagedURL, to: stagedFile.originalURL)
            } catch {
                firstError = firstError ?? error
            }
        }
        return firstError
    }

    private func removeStagedRecordingFiles(_ stagedFiles: [StagedRecordingDeletion]) {
        for stagedFile in stagedFiles where fileManager.fileExists(atPath: stagedFile.stagedURL.path) {
            do {
                try fileManager.removeItem(at: stagedFile.stagedURL)
            } catch {
                setError(String(localized: "Failed to delete recording file") + ": \(error.localizedDescription)")
            }
        }
    }

    private func recoverStagedRecordingDeletions(
        directoryURLs: [URL],
        trackedAudioPaths: Set<String>
    ) throws {
        for stagedURL in directoryURLs where stagedURL.lastPathComponent.hasPrefix(".deleting-") {
            guard let separatorRange = stagedURL.lastPathComponent.range(of: "--") else {
                throw HistoryViewModelError.invalidStagedRecordingName(stagedURL.lastPathComponent)
            }
            let originalName = String(stagedURL.lastPathComponent[separatorRange.upperBound...])
            guard !originalName.isEmpty else {
                throw HistoryViewModelError.invalidStagedRecordingName(stagedURL.lastPathComponent)
            }

            let originalURL = stagedURL.deletingLastPathComponent().appendingPathComponent(originalName)
            if trackedAudioPaths.contains(originalURL.path) {
                guard !fileManager.fileExists(atPath: originalURL.path) else {
                    try fileManager.removeItem(at: stagedURL)
                    continue
                }
                try fileManager.moveItem(at: stagedURL, to: originalURL)
            } else {
                try fileManager.removeItem(at: stagedURL)
            }
        }
    }

    private func migrateLegacyAudioFilePaths(
        in records: [TranscriptionRecord],
        recordingsDirectory: URL
    ) throws -> Bool {
        var changed = false
        for record in records {
            guard let audioFilePath = record.audioFilePath,
                  let migratedPath = try RecordingFileReference.migratedStoredPath(
                      from: audioFilePath,
                      recordingsDirectory: recordingsDirectory
                  ) else {
                continue
            }
            record.audioFilePath = migratedPath
            changed = true
        }
        return changed
    }

    private func repairMissingRecordingDurations(
        in records: [TranscriptionRecord],
        recordingsDirectory: URL
    ) throws -> Bool {
        var changed = false
        for record in records where record.duration <= 0 {
            guard let storedPath = record.audioFilePath else { continue }
            let url = try RecordingFileReference.fileURL(
                for: storedPath,
                recordingsDirectory: recordingsDirectory
            )
            guard fileManager.fileExists(atPath: url.path),
                  let duration = Self.readableAudioDuration(at: url) else { continue }
            record.duration = duration
            changed = true
        }
        return changed
    }

    private func recoverableRecordingURLs(from urls: [URL]) throws -> [(URL, TimeInterval)] {
        var recordingsByBaseName: [String: (URL, TimeInterval)] = [:]
        for url in urls {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (resourceValues.fileSize ?? 0) > 0,
                  let duration = Self.readableAudioDuration(at: url) else {
                AppLogger.error(
                    "Skipped unreadable interrupted recording: file=\(url.lastPathComponent)",
                    context: "HistoryViewModel"
                )
                continue
            }

            let baseName = url.deletingPathExtension().lastPathComponent
            if let existing = recordingsByBaseName[baseName] {
                // A process termination can land between publishing the finalized
                // M4A and deleting its durable CAF source. Both contain the same
                // recording; keep the completed M4A as the single history item.
                if existing.0.pathExtension.lowercased() == "caf",
                   url.pathExtension.lowercased() == "m4a" {
                    recordingsByBaseName[baseName] = (url, duration)
                }
            } else {
                recordingsByBaseName[baseName] = (url, duration)
            }
        }
        return Array(recordingsByBaseName.values)
    }

    private static func readableAudioDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url),
              file.fileFormat.sampleRate > 0 else { return nil }
        let duration = TimeInterval(file.length) / file.fileFormat.sampleRate
        return duration.isFinite && duration > 0 ? duration : nil
    }

    private func recordingsDirectory() throws -> URL {
        if let recordingsDirectoryOverride {
            return recordingsDirectoryOverride
        }
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw HistoryViewModelError.documentsDirectoryUnavailable
        }
        return documentsPath.appendingPathComponent(
            RecordingFileReference.directoryName,
            isDirectory: true
        )
    }

    private static func sortedUniqueTags(from records: [TranscriptionRecord]) -> [String] {
        var tagsByKey: [String: String] = [:]
        for record in records {
            for tag in record.tags {
                let key = foldedTagText(tag)
                tagsByKey[key] = tagsByKey[key] ?? tag
            }
        }

        return tagsByKey.values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private static func tagsAreEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func foldedTagText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

private struct StagedRecordingDeletion {
    let originalURL: URL
    let stagedURL: URL
}

private enum HistoryViewModelError: LocalizedError {
    case documentsDirectoryUnavailable
    case historyStoreUnavailable
    case deletionRollbackFailed(databaseError: String, restoreError: String)
    case invalidStagedRecordingName(String)
    case segmentEncodingFailed

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return String(localized: "Could not retrieve document directory for saved recordings.")
        case .historyStoreUnavailable:
            return String(localized: "History store is unavailable.")
        case .deletionRollbackFailed(let databaseError, let restoreError):
            return String(localized: "Failed to restore recording file")
                + ": database=\(databaseError), file=\(restoreError)"
        case .invalidStagedRecordingName(let name):
            return "Invalid staged recording filename: \(name)"
        case .segmentEncodingFailed:
            return "Failed to encode transcription segments."
        }
    }
}
