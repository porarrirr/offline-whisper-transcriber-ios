import SwiftUI

struct ContentView: View {
    @StateObject private var modelManager = ModelManager.shared
    
    var body: some View {
        Group {
            if modelManager.isModelReady {
                MainTabView()
                    .transition(.opacity)
            } else {
                ModelDownloadView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: modelManager.isModelReady)
    }
}
