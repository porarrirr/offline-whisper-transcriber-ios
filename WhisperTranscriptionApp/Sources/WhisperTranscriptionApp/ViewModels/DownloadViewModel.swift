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
    @Published var statusText = "Preparing model..."
    
    private var modelManager = ModelManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupBindings()
    }
    
    private func setupBindings() {
        modelManager.$isModelReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isReady in
                self?.isModelAvailable = isReady
                if isReady {
                    self?.isComplete = true
                    self?.isDownloading = false
                    self?.statusText = "Ready!"
                }
            }
            .store(in: &cancellables)

        modelManager.$isDownloading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isDownloading in
                self?.isDownloading = isDownloading
            }
            .store(in: &cancellables)

        modelManager.$downloadStatusText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statusText in
                self?.statusText = statusText
            }
            .store(in: &cancellables)

        modelManager.$downloadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.progress = progress
            }
            .store(in: &cancellables)

        modelManager.$downloadError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.errorMessage = error
            }
            .store(in: &cancellables)
    }
    
    func startDownload() {
        guard !isDownloading else { return }
        modelManager.downloadModel()
    }
    
    func checkAvailability() {
        modelManager.checkModelAvailability()
        if modelManager.isModelReady {
            isComplete = true
            statusText = "Model is already prepared"
        } else if AppSettings.shared.usesAppleSpeechBackend {
            modelManager.ensureModelAvailability()
            isDownloading = modelManager.isDownloading
            statusText = "Preparing speech model..."
        }
    }
}
