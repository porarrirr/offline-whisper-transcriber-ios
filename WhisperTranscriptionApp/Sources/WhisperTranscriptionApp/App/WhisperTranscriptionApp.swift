import SwiftUI
import SwiftData

@main
struct WhisperTranscriptionApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var recordingService = RecordingService()
    @Environment(\.scenePhase) private var scenePhase

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
                .environmentObject(recordingService)
                .onAppear {
                    performStartupMaintenance(modelContainer: modelContainer)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    recordingService.handleScenePhase(newPhase)
                }
        }
    }
    
    @MainActor
    private func performStartupMaintenance(modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        let viewModel = HistoryViewModel()
        viewModel.setModelContext(context)
        viewModel.importUntrackedRecordings()
        if AppSettings.shared.autoDeleteRecordings {
            viewModel.cleanupOldRecordings()
        }
    }
}
