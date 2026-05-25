import SwiftUI

struct MainTabView: View {
    @Environment(\.openURL) private var openURL
    @State private var selectedTab = 0
    @State private var availableUpdate: AppUpdateInfo?
    @AppStorage(WhisperAppDestination.pendingDestinationKey) private var pendingDestination = ""
    
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                TranscribeView()
            }
            .tabItem {
                Image(systemName: "waveform")
                Text("Transcribe")
            }
            .tag(0)
            
            NavigationStack {
                HistoryListView()
            }
            .tabItem {
                Image(systemName: "clock.arrow.circlepath")
                Text("History")
            }
            .tag(1)
            
            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Image(systemName: "gearshape.fill")
                Text("Settings")
            }
            .tag(2)
        }
        .tint(AppColors.accent)
        .task {
            await checkForAppStoreUpdate()
        }
        .onAppear {
            applyPendingDestination()
        }
        .onChange(of: pendingDestination) { _, _ in
            applyPendingDestination()
        }
        .alert("Update Available", isPresented: updateAlertBinding, presenting: availableUpdate) { update in
            Button("Later", role: .cancel) {}
            Button("Open App Store") {
                openURL(update.appStoreURL)
            }
        } message: { update in
            Text("Version \(update.remoteVersion) is available on the App Store.")
        }
    }

    private func applyPendingDestination() {
        guard let destination = WhisperAppDestination(rawValue: pendingDestination) else { return }
        pendingDestination = ""
        selectedTab = destination.tabIndex
    }

    private var updateAlertBinding: Binding<Bool> {
        Binding(
            get: { availableUpdate != nil },
            set: { isPresented in
                if !isPresented {
                    availableUpdate = nil
                }
            }
        )
    }

    private func checkForAppStoreUpdate() async {
        do {
            availableUpdate = try await AppUpdateChecker.shared.availableUpdate()
        } catch AppUpdateCheckError.appNotFoundInStorefront {
            AppLogger.info("App Store掲載が見つからないため、更新通知を表示しません", context: "AppUpdate")
        } catch {
            AppLogger.error("App Storeの更新チェックに失敗しました", context: "AppUpdate", error: error)
        }
    }
}
