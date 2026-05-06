import Foundation
import SwiftUI
import Combine

@MainActor
class DownloadViewModel: ObservableObject {
    @Published var progress: Double = 0
    @Published var isDownloading = false
    @Published var isComplete = false
    @Published var isModelAvailable = false
    @Published var errorMessage: String?
    @Published var statusText = "モデルを準備しています..."
    
    private var modelManager = ModelManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    
    init() {
        setupBindings()
    }
    
    private func setupBindings() {
        modelManager.$isModelReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReady in
                self?.isModelAvailable = isReady
            }
            .store(in: &cancellables)
    }
    
    func startDownload() {
        guard !isDownloading else { return }
        
        isDownloading = true
        statusText = "モデルをダウンロード中..."
        
        modelManager.downloadModel()
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            self.progress = self.modelManager.downloadProgress
            
            if self.modelManager.isModelReady {
                self.isComplete = true
                self.isDownloading = false
                self.statusText = "準備完了！"
                timer.invalidate()
            }
            
            if let error = self.modelManager.downloadError {
                self.errorMessage = error
                self.isDownloading = false
                timer.invalidate()
            }
        }
    }
    
    func checkAvailability() {
        modelManager.checkModelAvailability()
        if modelManager.isModelReady {
            isComplete = true
            statusText = "モデルはすでに準備されています"
        }
    }
    
    deinit {
        timer?.invalidate()
    }
}
