import SwiftUI
import SwiftData

@main
struct WhisperTranscriptionApp: App {
    private let modelContainer: ModelContainer?
    private let modelContainerErrorMessage: String?
    @StateObject private var recordingService = RecordingService.shared
    @StateObject private var settings = AppSettings.shared
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
            Group {
                if let modelContainer {
                    ContentView()
                        .modelContainer(modelContainer)
                        .environmentObject(recordingService)
                        .onAppear {
                            performStartupMaintenance(modelContainer: modelContainer)
                            recordingService.handleBecameActive()
                        }
                        .onChange(of: scenePhase) { _, newPhase in
                            recordingService.handleScenePhase(newPhase)
                        }
                } else {
                    DataStoreUnavailableView(errorMessage: modelContainerErrorMessage)
                }
            }
            .preferredColorScheme(settings.appAppearance.preferredColorScheme)
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

private extension AppAppearance {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

private struct DataStoreUnavailableView: View {
    let errorMessage: String?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 56))
                    .foregroundColor(Theme.rec)

                Text("History Store Unavailable")
                    .font(Theme.sans(20, weight: .bold))
                    .foregroundColor(Theme.textPrimary)

                Text("The saved history database could not be opened. Existing recording files are left untouched.")
                    .font(Theme.sans(15))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.sans(12))
                        .foregroundColor(Theme.rec)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
    }
}
