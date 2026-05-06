import SwiftUI
import SwiftData

@main
struct WhisperTranscriptionApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(for: TranscriptionRecord.self)
                .onAppear {
                    performAutoCleanup()
                }
        }
    }
    
    @MainActor
    private func performAutoCleanup() {
        guard AppSettings.shared.autoDeleteRecordings else { return }
        
        do {
            let container = try ModelContainer(for: TranscriptionRecord.self)
            let context = ModelContext(container)
            let viewModel = HistoryViewModel()
            viewModel.setModelContext(context)
            viewModel.cleanupOldRecordings()
        } catch {
            assertionFailure("Failed to perform auto cleanup: \(error)")
        }
    }
}
