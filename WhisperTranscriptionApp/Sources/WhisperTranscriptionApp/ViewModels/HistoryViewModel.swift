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
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
        fetchRecords()
    }
    
    func fetchRecords() {
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
            setError("履歴の読み込みに失敗しました: \(error.localizedDescription)")
        }
    }
    
    func deleteRecord(_ record: TranscriptionRecord) {
        guard let modelContext = modelContext else { return }
        modelContext.delete(record)
        do {
            try modelContext.save()
        } catch {
            setError("履歴の削除に失敗しました: \(error.localizedDescription)")
        }
        fetchRecords()
    }
    
    func toggleFavorite(_ record: TranscriptionRecord) {
        record.isFavorite.toggle()
        do {
            try modelContext?.save()
        } catch {
            record.isFavorite.toggle()
            setError("お気に入りの更新に失敗しました: \(error.localizedDescription)")
        }
        fetchRecords()
    }
    
    func exportRecord(_ record: TranscriptionRecord, format: ExportFormat) -> URL? {
        return TranscriptionExporter.export(record: record, format: format)
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
            setError("古い録音ファイルの削除に失敗しました: \(error.localizedDescription)")
        }
    }

    private func setError(_ message: String) {
        errorMessage = message
        AppLogger.error(message, context: "HistoryViewModel")
    }
}
