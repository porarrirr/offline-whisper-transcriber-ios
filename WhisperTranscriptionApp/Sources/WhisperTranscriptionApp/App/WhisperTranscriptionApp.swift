import SwiftUI
import SwiftData

@main
struct WhisperTranscriptionApp: App {
    private let modelContainer: ModelContainer?
    private let modelContainerErrorMessage: String?
    @StateObject private var recordingService = RecordingService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            modelContainer = try ModelContainer(for: TranscriptionRecord.self)
            modelContainerErrorMessage = nil
        } catch {
            AppLogger.error("SwiftDataストアの初期化に失敗しました", context: "App", error: error)
            modelContainer = nil
            modelContainerErrorMessage = error.localizedDescription
        }
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer {
                ContentView()
                    .modelContainer(modelContainer)
                    .environmentObject(recordingService)
                    .onAppear {
                        performStartupMaintenance(modelContainer: modelContainer)
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        recordingService.handleScenePhase(newPhase)
                    }
            } else {
                DataStoreUnavailableView(errorMessage: modelContainerErrorMessage)
                    .preferredColorScheme(.dark)
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
        ModelManager.shared.scheduleWhisperSessionStartIfNeeded()
    }
}

private struct DataStoreUnavailableView: View {
    let errorMessage: String?

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 56))
                    .foregroundColor(AppColors.warning)

                Text("History Store Unavailable")
                    .font(AppFonts.title2)
                    .foregroundColor(AppColors.textPrimary)

                Text("The saved history database could not be opened. Existing recording files are left untouched.")
                    .font(AppFonts.callout)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage {
                    Text(errorMessage)
                        .font(AppFonts.caption)
                        .foregroundColor(AppColors.warning)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
    }
}
