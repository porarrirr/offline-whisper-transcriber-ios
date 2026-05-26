import Foundation
import SwiftData
import UIKit

@MainActor
class HistoryViewModel: ObservableObject {
    @Published var records: [TranscriptionRecord] = []
    @Published var searchText = ""
    @Published var filterFavorite = false
    @Published var errorMessage: String?
    
    private var modelContext: ModelContext?
    private var fetchTask: Task<Void, Never>?
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        fetchRecords()
    }
    
    func fetchRecords() {
        fetchTask?.cancel()
        performFetchRecords()
    }

    private func performFetchRecords() {
        guard let modelContext = modelContext else { return }
        
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        do {
            var allRecords = try modelContext.fetch(descriptor)
            
            if !searchText.isEmpty {
                allRecords = allRecords.filter {
                    $0.text.localizedCaseInsensitiveContains(searchText) ||
                    $0.title.localizedCaseInsensitiveContains(searchText)
                }
            }
            
            if filterFavorite {
                allRecords = allRecords.filter { $0.isFavorite }
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
    
    func deleteRecord(_ record: TranscriptionRecord) {
        guard let modelContext = modelContext else { return }
        let audioFilePath = record.audioFilePath
        modelContext.delete(record)
        do {
            try modelContext.save()
            deleteRecordingFileIfNeeded(at: audioFilePath)
        } catch {
            setError(String(localized: "Failed to delete history") + ": \(error.localizedDescription)")
        }
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
    
    func exportRecord(_ record: TranscriptionRecord, format: ExportFormat) -> URL? {
        return TranscriptionExporter.export(record: record, format: format)
    }

    func exportRecordingAudio(_ record: TranscriptionRecord) -> URL? {
        RecordingAudioExporter.export(record: record)
    }
    
    func cleanupOldRecordings() {
        guard let modelContext = modelContext else { return }
        
        let cutoffDate = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        do {
            let allRecords = try modelContext.fetch(descriptor)
            for record in allRecords {
                if record.createdAt < cutoffDate,
                   let audioPath = record.audioFilePath,
                   FileManager.default.fileExists(atPath: audioPath) {
                    try FileManager.default.removeItem(atPath: audioPath)
                }
            }
        } catch {
            setError(String(localized: "Failed to delete old recordings") + ": \(error.localizedDescription)")
        }
    }

    func importUntrackedRecordings() {
        guard let modelContext = modelContext else { return }

        do {
            let recordingsDirectory = try recordingsDirectory()
            guard FileManager.default.fileExists(atPath: recordingsDirectory.path) else { return }

            let descriptor = FetchDescriptor<TranscriptionRecord>()
            let records = try modelContext.fetch(descriptor)
            let trackedAudioPaths = Set(records.compactMap(\.audioFilePath))
            let recordingURLs = try FileManager.default.contentsOfDirectory(
                at: recordingsDirectory,
                includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

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
            fetchRecords()
        } catch {
            setError(String(localized: "Failed to recover saved recordings") + ": \(error.localizedDescription)")
        }
    }

    private func setError(_ message: String) {
        errorMessage = message
        AppLogger.error(message, context: "HistoryViewModel")
    }

    private func deleteRecordingFileIfNeeded(at path: String?) {
        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            setError(String(localized: "Failed to delete recording file") + ": \(error.localizedDescription)")
        }
    }

    private func recordingsDirectory() throws -> URL {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw HistoryViewModelError.documentsDirectoryUnavailable
        }
        return documentsPath.appendingPathComponent("Recordings", isDirectory: true)
    }
}

private enum HistoryViewModelError: LocalizedError {
    case documentsDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return String(localized: "Could not retrieve document directory for saved recordings.")
        }
    }
}
