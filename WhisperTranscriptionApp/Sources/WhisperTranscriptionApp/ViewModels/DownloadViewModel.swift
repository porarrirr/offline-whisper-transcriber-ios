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
    @Published var isWaitingForSpeechAsset = false
    @Published var speechAssetSnapshot = SpeechAssetSnapshot()
    
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
                self?.isComplete = isReady
                if isReady {
                    self?.isDownloading = false
                    self?.statusText = "Ready!"
                } else if self?.isDownloading == false {
                    self?.statusText = "Preparing model..."
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

        modelManager.$isWaitingForSpeechAsset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isWaiting in
                self?.isWaitingForSpeechAsset = isWaiting
            }
            .store(in: &cancellables)

        modelManager.$speechAssetSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.speechAssetSnapshot = snapshot
                self?.isWaitingForSpeechAsset = {
                    if case .systemManagedPending = snapshot.state { return true }
                    return false
                }()
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
    
    func checkAvailability(autoPrepareAppleSpeech: Bool = false) {
        modelManager.checkModelAvailability()
        if modelManager.isModelReady {
            isComplete = true
            statusText = "Model is already prepared"
        } else if AppSettings.shared.usesAppleSpeechBackend {
            isComplete = false
            modelManager.ensureModelAvailability()
            if autoPrepareAppleSpeech,
               !modelManager.speechAssetSnapshot.isOperationActive,
               !modelManager.isModelReady {
                modelManager.downloadModel()
            }
            isDownloading = modelManager.isDownloading || autoPrepareAppleSpeech
            statusText = modelManager.speechAssetSnapshot.statusTitle
        } else {
            isComplete = false
            isModelAvailable = false
        }
    }

    func cancelSpeechAsset() {
        modelManager.cancelDownload()
    }
}
