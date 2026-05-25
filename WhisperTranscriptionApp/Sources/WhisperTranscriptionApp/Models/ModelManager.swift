import Foundation
import Speech
import SwiftData
import UIKit

@MainActor
class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()

    @Published var isModelReady = false
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var downloadError: String?
    @Published var currentTranscriptionModel: TranscriptionModel = .whisper(.largeV3TurboQ5_0)
    @Published var isVADModelReady = false
    @Published var vadDownloadProgress: Double = 0
    @Published var isVADDownloading = false
    @Published var vadDownloadError: String?

    private var downloadTask: URLSessionDownloadTask?
    private var vadDownloadTask: URLSessionDownloadTask?
    private var modelDownloadSession: URLSession?
    private var vadDownloadSession: URLSession?
    private var activeWhisperDownloadSize: WhisperModelSize?
    private var speechAssetDownloadTask: Task<Void, Never>?
    private let vadModelFileName = "ggml-silero-v6.2.0.bin"
    private let vadModelURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!

    var modelPath: String {
        whisperModelURL.path
    }

    var vadModelPath: String {
        vadModelFileURL.path
    }

    var usesWhisperBackend: Bool {
        currentTranscriptionModel.backend.isWhisper
    }

    var usesAppleSpeechBackend: Bool {
        currentTranscriptionModel.backend.isAppleSpeech
    }

    private var whisperModelURL: URL {
        guard let size = currentTranscriptionModel.whisperModelSize else {
            preconditionFailure("Whisper model path requested for non-Whisper selection")
        }
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            preconditionFailure("Documents directory is unavailable")
        }
        return documentsPath.appendingPathComponent(size.fileName)
    }

    private var vadModelFileURL: URL {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            preconditionFailure("Documents directory is unavailable")
        }
        return documentsPath.appendingPathComponent(vadModelFileName)
    }

    private override init() {
        currentTranscriptionModel = AppSettings.shared.selectedTranscriptionModel
        super.init()
        ensureModelAvailability()
        checkVADModelAvailability()
    }

    func checkModelAvailability() {
        ensureModelAvailability()
    }

    func ensureModelAvailability() {
        Task { @MainActor in
            await refreshModelReadyState(autoInstallSystemAssets: true)
        }
    }

    func refreshModelReadyState(autoInstallSystemAssets: Bool = false) async {
        switch currentTranscriptionModel.backend {
        case .whisper:
            let exists = FileManager.default.fileExists(atPath: whisperModelURL.path)
            isModelReady = exists
        case .appleSpeech(let locale):
            guard #available(iOS 26.0, *) else {
                isModelReady = false
                return
            }
            let installed = await AppleSpeechTranscriptionService().assetsInstalled(for: locale)
            isModelReady = installed
            if !installed && autoInstallSystemAssets {
                downloadAppleSpeechAssets(locale: locale)
            }
        }
    }

    func checkVADModelAvailability() {
        let exists = FileManager.default.fileExists(atPath: vadModelPath)
        isVADModelReady = exists
    }

    func switchModel(model: TranscriptionModel) {
        downloadTask?.cancel()
        downloadTask = nil
        activeWhisperDownloadSize = nil
        speechAssetDownloadTask?.cancel()
        speechAssetDownloadTask = nil
        currentTranscriptionModel = model
        AppSettings.shared.selectedTranscriptionModel = model
        isDownloading = false
        downloadProgress = 0
        downloadError = nil
        Task { @MainActor in
            await refreshModelReadyState(autoInstallSystemAssets: true)
        }
    }

    func downloadModel(model: TranscriptionModel? = nil) {
        let targetModel = model ?? currentTranscriptionModel
        if let model, model != currentTranscriptionModel {
            cancelDownload()
            currentTranscriptionModel = model
            AppSettings.shared.selectedTranscriptionModel = model
        }

        switch targetModel.backend {
        case .whisper:
            guard let size = targetModel.whisperModelSize else { return }
            downloadWhisperModel(size: size)
        case .appleSpeech(let locale):
            downloadAppleSpeechAssets(locale: locale)
        }
    }

    private func downloadWhisperModel(size: WhisperModelSize) {
        guard !isDownloading else { return }
        guard let url = size.downloadURL else {
            setDownloadError("ダウンロードURLが無効です")
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        activeWhisperDownloadSize = size

        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        modelDownloadSession = session

        downloadTask = session.downloadTask(with: url)
        downloadTask?.taskDescription = "mainModel"
        downloadTask?.resume()
    }

    private func downloadAppleSpeechAssets(locale: AppleSpeechLocale) {
        guard !isDownloading else { return }
        guard #available(iOS 26.0, *) else {
            setDownloadError(AppleSpeechTranscriptionError.transcriptionUnavailable.localizedDescription)
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        speechAssetDownloadTask?.cancel()

        speechAssetDownloadTask = Task { @MainActor in
            do {
                try await AppleSpeechTranscriptionService().ensureAssetsInstalled(for: locale) { [weak self] progress in
                    self?.downloadProgress = progress
                }
                self.isModelReady = true
                self.isDownloading = false
                self.downloadProgress = 1
                self.downloadError = nil
            } catch {
                self.setDownloadError(error.localizedDescription)
                self.isDownloading = false
                await self.refreshModelReadyState(autoInstallSystemAssets: false)
            }
            self.speechAssetDownloadTask = nil
        }
    }

    func downloadVADModel() {
        guard !isVADDownloading else { return }

        isVADDownloading = true
        vadDownloadProgress = 0
        vadDownloadError = nil

        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        vadDownloadSession = session

        vadDownloadTask = session.downloadTask(with: vadModelURL)
        vadDownloadTask?.taskDescription = "vadModel"
        vadDownloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        activeWhisperDownloadSize = nil
        speechAssetDownloadTask?.cancel()
        speechAssetDownloadTask = nil
        isDownloading = false
        downloadProgress = 0
    }

    func cancelVADDownload() {
        vadDownloadTask?.cancel()
        vadDownloadTask = nil
        isVADDownloading = false
        vadDownloadProgress = 0
    }

    func getModelSize() -> String? {
        switch currentTranscriptionModel.backend {
        case .whisper:
            guard FileManager.default.fileExists(atPath: whisperModelURL.path) else { return nil }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: whisperModelURL.path)
                if let size = attributes[.size] as? Int64 {
                    let formatter = ByteCountFormatter()
                    formatter.countStyle = .file
                    return formatter.string(fromByteCount: size)
                }
            } catch {
                setDownloadError(String(localized: "Failed to get model size") + ": \(error.localizedDescription)")
            }
            return nil
        case .appleSpeech:
            return nil
        }
    }

    func deleteCurrentModel() {
        switch currentTranscriptionModel.backend {
        case .whisper:
            if FileManager.default.fileExists(atPath: whisperModelURL.path) {
                do {
                    try FileManager.default.removeItem(atPath: whisperModelURL.path)
                    isModelReady = false
                    downloadError = nil
                } catch {
                    setDownloadError(String(localized: "Error deleting model") + ": \(error.localizedDescription)")
                }
            }
        case .appleSpeech(let locale):
            if #available(iOS 26.0, *) {
                Task { @MainActor in
                    _ = await AssetInventory.release(reservedLocale: locale.locale)
                    await refreshModelReadyState(autoInstallSystemAssets: false)
                }
            }
        }
    }

    func deleteVADModel() {
        if FileManager.default.fileExists(atPath: vadModelPath) {
            do {
                try FileManager.default.removeItem(atPath: vadModelPath)
                isVADModelReady = false
                vadDownloadError = nil
            } catch {
                setVADDownloadError(String(localized: "Error deleting VAD model") + ": \(error.localizedDescription)")
            }
        }
    }

    func deleteAllModels() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            setDownloadError(String(localized: "Could not retrieve documents directory for saving models."))
            return
        }
        for size in WhisperModelSize.allCases {
            let path = documentsPath.appendingPathComponent(size.fileName).path
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    setDownloadError(String(localized: "Error deleting model") + ": \(error.localizedDescription)")
                    return
                }
            }
        }
        isModelReady = false
    }

    private func setDownloadError(_ message: String) {
        downloadError = message
        AppLogger.error(message, context: "ModelManager")
    }

    private func setVADDownloadError(_ message: String) {
        vadDownloadError = message
        AppLogger.error(message, context: "ModelManager")
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if downloadTask.taskDescription == "vadModel" {
            vadDownloadProgress = progress
        } else {
            downloadProgress = progress
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let isVADModelDownload = downloadTask.taskDescription == "vadModel"
            let destinationURL: URL
            if isVADModelDownload {
                destinationURL = vadModelFileURL
            } else {
                guard let whisperSize = activeWhisperDownloadSize else {
                    setDownloadError(String(localized: "Downloaded model target was lost. Please download the model again."))
                    isDownloading = false
                    return
                }
                guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                    preconditionFailure("Documents directory is unavailable")
                }
                destinationURL = documentsPath.appendingPathComponent(whisperSize.fileName)
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            if isVADModelDownload {
                isVADModelReady = true
                isVADDownloading = false
                vadDownloadProgress = 1.0
                vadDownloadTask = nil
            } else {
                isModelReady = true
                isDownloading = false
                downloadProgress = 1.0
                self.downloadTask = nil
                activeWhisperDownloadSize = nil
            }
        } catch {
            if downloadTask.taskDescription == "vadModel" {
                setVADDownloadError(String(localized: "Error saving VAD model") + ": \(error.localizedDescription)")
                isVADDownloading = false
            } else {
                setDownloadError(String(localized: "Error saving model file") + ": \(error.localizedDescription)")
                isDownloading = false
                activeWhisperDownloadSize = nil
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled {
                if task.taskDescription == "vadModel" {
                    vadDownloadTask = nil
                    isVADDownloading = false
                } else {
                    downloadTask = nil
                    activeWhisperDownloadSize = nil
                    isDownloading = false
                }
                return
            }
            if task.taskDescription == "vadModel" {
                setVADDownloadError(String(localized: "Error downloading VAD model") + ": \(error.localizedDescription)")
                isVADDownloading = false
                vadDownloadTask = nil
            } else {
                setDownloadError(String(localized: "Download error") + ": \(error.localizedDescription)")
                isDownloading = false
                downloadTask = nil
                activeWhisperDownloadSize = nil
            }
        }
    }
}
