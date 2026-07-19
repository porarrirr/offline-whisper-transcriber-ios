import SwiftUI

struct ContentView: View {
    @StateObject private var modelManager = ModelManager.shared
    @State private var hasEnteredMainApp = false
    
    var body: some View {
        Group {
            if modelManager.isModelReady || hasEnteredMainApp {
                MainTabView()
            } else {
                ModelDownloadView()
            }
        }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: modelManager.isModelReady)
            .onAppear {
                if modelManager.isModelReady {
                    hasEnteredMainApp = true
                }
            }
            .onChange(of: modelManager.isModelReady) { _, isReady in
                if isReady {
                    hasEnteredMainApp = true
                }
            }
    }
}
