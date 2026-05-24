import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    
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
    }
}
