import SwiftUI
import SwiftData

@main
struct WhisperTranscriptionApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(for: TranscriptionRecord.self)
        } catch {
            AppLogger.error("SwiftDataストアの初期化に失敗しました", context: "App", error: error)
            fatalError("SwiftData store initialization failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .onAppear {
                    performAutoCleanup(modelContainer: modelContainer)
                }
        }
    }
    
    @MainActor
    private func performAutoCleanup(modelContainer: ModelContainer) {
        guard AppSettings.shared.autoDeleteRecordings else { return }
        
        do {
            let context = ModelContext(modelContainer)
            let viewModel = HistoryViewModel()
            viewModel.setModelContext(context)
            viewModel.cleanupOldRecordings()
        } catch {
            AppLogger.error("起動時の自動クリーンアップに失敗しました", context: "App", error: error)
            assertionFailure("Failed to perform auto cleanup: \(error)")
        }
    }
}
