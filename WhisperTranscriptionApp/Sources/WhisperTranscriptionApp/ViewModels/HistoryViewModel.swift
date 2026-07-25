import Foundation
import SwiftData
import UIKit

@MainActor
class HistoryViewModel: ObservableObject {
    @Published var records: [TranscriptionRecord] = []
    @Published var searchText = ""
    @Published var filterFavorite = false
    @Published var selectedTag: String?
    @Published private(set) var availableTags: [String] = []
    @Published var errorMessage: String?
    
    private var modelContext: ModelContext?
    private var fetchTask: Task<Void, Never>?
    private var availableTagsNeedRefresh = true
    private let fileManager: FileManager
    private let recordingsDirectoryOverride: URL?

    init(fileManager: FileManager = .default, recordingsDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.recordingsDirectoryOverride = recordingsDirectory
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
            refreshAvailableTagsIfNeeded(modelContext: modelContext)
            
            if !searchText.isEmpty {
                allRecords = allRecords.filter { $0.matchesSearchText(searchText) }
            }

            if let selectedTag {
                allRecords = allRecords.filter { $0.hasTag(selectedTag) }
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
    
    @discardableResult
    func deleteRecord(_ record: TranscriptionRecord) -> Bool {
        deleteRecords([record])
    }

    @discardableResult
    func deleteRecords(_ recordsToDelete: [TranscriptionRecord]) -> Bool {
        guard let modelContext = modelContext else { return false }
        let audioFilePaths = Array(Set(recordsToDelete.compactMap(\.audioFilePath)))
        let stagedFiles: [StagedRecordingDeletion]
        do {
            stagedFiles = try stageRecordingFilesForDeletion(at: audioFilePaths)
        } catch {
            setError(String(localized: "Failed to delete recording file") + ": \(error.localizedDescription)")
            return false
        }

        recordsToDelete.forEach { modelContext.delete($0) }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            if let restoreError = restoreStagedRecordingFiles(stagedFiles) {
                setError(
                    HistoryViewModelError.deletionRollbackFailed(
                        databaseError: error.localizedDescription,
                        restoreError: restoreError.localizedDescription
                    ).localizedDescription
                )
            } else {
                setError(String(localized: "Failed to delete history") + ": \(error.localizedDescription)")
            }
            fetchRecords()
            return false
        }

        removeStagedRecordingFiles(stagedFiles)
        availableTagsNeedRefresh = true
        fetchRecords()
        return true
    }

    func updateTags(_ record: TranscriptionRecord, tagsInput: String) {
        updateTags(record, tags: TranscriptionRecord.normalizedTags(from: tagsInput))
    }

    func updateTags(_ record: TranscriptionRecord, tags: [String]) {
        let previousTagsJSON = record.tagsJSON
        record.updateTags(tags)
        do {
            try modelContext?.save()
        } catch {
            record.tagsJSON = previousTagsJSON
            setError(String(localized: "Failed to update tags") + ": \(error.localizedDescription)")
        }
        availableTagsNeedRefresh = true
        fetchRecords()
    }

    func toggleTagFilter(_ tag: String) {
        if selectedTag == tag {
            selectedTag = nil
        } else {
            selectedTag = tag
        }
        fetchRecords()
    }

    func clearTagFilter() {
        selectedTag = nil
        fetchRecords()
    }
    
    func toggleFavorite(_ record: TranscriptionRecord) {
        record.isFavorite.toggle()
        do {
            try modelContext?.save()
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
        do {
            try modelContext?.save()
        } catch {
            record.title = previousTitle
            setError(String(localized: "Failed to update title") + ": \(error.localizedDescription)")
        }
        fetchRecords()
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
            try modelContext.save()
            errorMessage = nil
            return true
        } catch {
            record.text = previousText
            record.segmentsJSON = previousSegmentsJSON
            setError(String(localized: "Failed to update transcription") + ": \(error.localizedDescription)")
            return false
        }
    }
    
    func exportRecord(_ record: TranscriptionRecord, format: ExportFormat) -> URL? {
        return TranscriptionExporter.export(record: record, format: format)
    }

    func exportRecordingAudio(_ record: TranscriptionRecord) -> URL? {
        RecordingAudioExporter.export(record: record)
    }
    
    func cleanupOldRecordings(referenceDate: Date = Date()) {
        guard let modelContext = modelContext else { return }
        
        let cutoffDate = referenceDate.addingTimeInterval(-7 * 24 * 60 * 60)
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        do {
            let allRecords = try modelContext.fetch(descriptor)
            for record in allRecords where record.createdAt < cutoffDate && !record.isFavorite {
                guard let audioPath = record.audioFilePath else { continue }
                try removeExpiredRecording(
                    from: record,
                    audioPath: audioPath,
                    modelContext: modelContext
                )
            }
        } catch {
            setError(String(localized: "Failed to delete old recordings") + ": \(error.localizedDescription)")
        }
    }

    private func removeExpiredRecording(
        from record: TranscriptionRecord,
        audioPath: String,
        modelContext: ModelContext
    ) throws {
        record.audioFilePath = nil
        do {
            try modelContext.save()
        } catch {
            record.audioFilePath = audioPath
            throw error
        }

        guard fileManager.fileExists(atPath: audioPath) else { return }

        do {
            try fileManager.removeItem(atPath: audioPath)
        } catch {
            record.audioFilePath = audioPath
            do {
                try modelContext.save()
            } catch let restoreError {
                throw HistoryViewModelError.cleanupRollbackFailed(
                    deletionError: error.localizedDescription,
                    restoreError: restoreError.localizedDescription
                )
            }
            throw error
        }
    }

    func importUntrackedRecordings() {
        guard let modelContext = modelContext else { return }

        do {
            let recordingsDirectory = try recordingsDirectory()
            guard fileManager.fileExists(atPath: recordingsDirectory.path) else { return }

            let descriptor = FetchDescriptor<TranscriptionRecord>()
            let records = try modelContext.fetch(descriptor)
            let trackedAudioPaths = Set(records.compactMap(\.audioFilePath))
            let directoryURLs = try fileManager.contentsOfDirectory(
                at: recordingsDirectory,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: []
            )
            try recoverStagedRecordingDeletions(
                directoryURLs: directoryURLs,
                trackedAudioPaths: trackedAudioPaths
            )
            let recordingURLs = directoryURLs.filter { !$0.lastPathComponent.hasPrefix(".") }

            var importedRecords = 0
            for url in recordingURLs where url.pathExtension.localizedCaseInsensitiveCompare("m4a") == .orderedSame {
                guard !trackedAudioPaths.contains(url.path) else { continue }
                let resourceValues = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                guard (resourceValues.fileSize ?? 0) > 0 else { continue }
                let createdAt = resourceValues.creationDate ?? Date()
                let record = TranscriptionRecord(
                    title: TranscriptionRecord.defaultTitle(for: createdAt),
                    text: "",
                    sourceType: .recording,
                    audioFilePath: url.path,
                    duration: 0,
                    createdAt: createdAt
                )
                modelContext.insert(record)
                importedRecords += 1
            }

            guard importedRecords > 0 else { return }
            try modelContext.save()
            availableTagsNeedRefresh = true
            fetchRecords()
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
            availableTags = Self.sortedUniqueTags(from: allRecords)
            if let selectedTag,
               !availableTags.contains(where: { Self.tagsAreEqual($0, selectedTag) }) {
                self.selectedTag = nil
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
            for path in paths where fileManager.fileExists(atPath: path) {
                let sourceURL = URL(fileURLWithPath: path)
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

    private func recordingsDirectory() throws -> URL {
        if let recordingsDirectoryOverride {
            return recordingsDirectoryOverride
        }
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw HistoryViewModelError.documentsDirectoryUnavailable
        }
        return documentsPath.appendingPathComponent("Recordings", isDirectory: true)
    }

    private static func sortedUniqueTags(from records: [TranscriptionRecord]) -> [String] {
        var tagsByKey: [String: String] = [:]
        for record in records {
            for tag in record.tags {
                let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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
}

private struct StagedRecordingDeletion {
    let originalURL: URL
    let stagedURL: URL
}

private enum HistoryViewModelError: LocalizedError {
    case documentsDirectoryUnavailable
    case cleanupRollbackFailed(deletionError: String, restoreError: String)
    case deletionRollbackFailed(databaseError: String, restoreError: String)
    case invalidStagedRecordingName(String)
    case segmentEncodingFailed

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return String(localized: "Could not retrieve document directory for saved recordings.")
        case .cleanupRollbackFailed(let deletionError, let restoreError):
            return "Recording deletion failed (\(deletionError)); restoring its history reference also failed (\(restoreError))."
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
