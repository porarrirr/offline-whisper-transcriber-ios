import SwiftUI

struct ContentView: View {
    @StateObject private var modelManager = ModelManager.shared
    
    var body: some View {
        MainTabView()
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: modelManager.isModelReady)
    }
}
