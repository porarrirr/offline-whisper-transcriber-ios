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
    @Published var downloadStatusText = "Preparing model..."
    @Published var currentTranscriptionModel: TranscriptionModel = .whisper(.largeV3TurboQ5_0)
    @Published var isVADModelReady = false
    @Published var vadDownloadProgress: Double = 0
    @Published var isVADDownloading = false
    @Published var vadDownloadError: String?
    @Published private(set) var isTranscriptionInProgress = false

    private var downloadTask: URLSessionDownloadTask?
    private var vadDownloadTask: URLSessionDownloadTask?
    private var modelDownloadSession: URLSession?
    private var vadDownloadSession: URLSession?
    private var activeWhisperDownloadSize: WhisperModelSize?
    private var activeWhisperDownloadIncludesModel = false
    private var coreMLEncoderInstallTask: Task<Void, Never>?
    private var speechAssetDownloadTask: Task<Void, Never>?
    private var transcriptionOperationCount = 0
    private let vadModelFileName = "ggml-silero-v6.2.0.bin"
    private let vadModelURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin")!

    var modelPath: String {
        whisperModelURL.path
    }

    var coreMLEncoderPath: String {
        whisperCoreMLEncoderURL.path
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
        return whisperModelURL(for: size)
    }

    private var whisperCoreMLEncoderURL: URL {
        guard let size = currentTranscriptionModel.whisperModelSize else {
            preconditionFailure("Whisper Core ML encoder path requested for non-Whisper selection")
        }
        return whisperCoreMLEncoderURL(for: size)
    }

    private var documentsURL: URL {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            preconditionFailure("Documents directory is unavailable")
        }
        return documentsPath
    }

    private var vadModelFileURL: URL {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            preconditionFailure("Documents directory is unavailable")
        }
        return documentsPath.appendingPathComponent(vadModelFileName)
    }

    func whisperReadinessMessage() -> String {
        guard let size = currentTranscriptionModel.whisperModelSize else {
            return String(localized: "Model Ready")
        }
        let readiness = whisperReadiness(for: size)
        if readiness.modelExists {
            return String(localized: "Model Ready")
        }
        if !readiness.modelExists {
            return String(localized: "Please download model")
        }
        return String(localized: "Core ML encoder is not available for this model.")
    }

    func currentTranscriptionReadinessError() -> String? {
        switch currentTranscriptionModel.backend {
        case .whisper:
            return currentWhisperModelIsReady() ? nil : whisperReadinessMessage()
        case .appleSpeech:
            guard #available(iOS 26.0, *) else {
                return AppleSpeechTranscriptionError.transcriptionUnavailable.localizedDescription
            }
            guard SpeechTranscriber.isAvailable else {
                return AppleSpeechTranscriptionError.transcriptionUnavailable.localizedDescription
            }
            if isModelReady {
                return nil
            }
            if let downloadError {
                return downloadError
            }
            return String(localized: "Preparing speech model...")
        }
    }

    func currentTranscriptionModelCanTranscribe() -> Bool {
        currentTranscriptionReadinessError() == nil
    }

    func currentWhisperModelIsReady() -> Bool {
        guard let size = currentTranscriptionModel.whisperModelSize else { return false }
        return whisperReadiness(for: size).modelExists
    }

    func currentWhisperModelIsReadyForCoreML() -> Bool {
        guard let size = currentTranscriptionModel.whisperModelSize else { return false }
        return whisperReadiness(for: size).isReady
    }

    func beginTranscriptionOperation() {
        transcriptionOperationCount += 1
        isTranscriptionInProgress = true
    }

    func endTranscriptionOperation() {
        transcriptionOperationCount = max(0, transcriptionOperationCount - 1)
        isTranscriptionInProgress = transcriptionOperationCount > 0
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
            isModelReady = currentWhisperModelIsReady()
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
        guard model != currentTranscriptionModel else { return }
        guard modelMutationIsAllowed() else {
            AppSettings.shared.selectedTranscriptionModel = currentTranscriptionModel
            return
        }
        downloadTask?.cancel()
        downloadTask = nil
        activeWhisperDownloadSize = nil
        activeWhisperDownloadIncludesModel = false
        coreMLEncoderInstallTask?.cancel()
        coreMLEncoderInstallTask = nil
        speechAssetDownloadTask?.cancel()
        speechAssetDownloadTask = nil
        currentTranscriptionModel = model
        AppSettings.shared.selectedTranscriptionModel = model
        Task {
            await WhisperModelService.shared.invalidateAndUnload()
        }
        isDownloading = false
        downloadProgress = 0
        downloadStatusText = "Preparing model..."
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

        let readiness = whisperReadiness(for: size)
        guard !readiness.isReady else {
            isModelReady = true
            downloadProgress = 1
            downloadError = nil
            scheduleWhisperSessionStartIfNeeded()
            return
        }

        let requiredBytes = size.requiredDownloadBytes(
            modelExists: readiness.modelExists,
            encoderExists: readiness.encoderExists
        )
        do {
            try DiskSpaceChecker.ensureAvailable(at: documentsURL, requiredBytes: requiredBytes)
        } catch {
            setDownloadError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadStatusText = "Preparing model..."
        downloadError = nil
        activeWhisperDownloadSize = size
        activeWhisperDownloadIncludesModel = !readiness.modelExists

        if readiness.modelExists {
            startWhisperCoreMLEncoderDownload(size: size)
            return
        }

        guard let url = size.downloadURL else {
            setDownloadError("ダウンロードURLが無効です")
            isDownloading = false
            return
        }

        downloadStatusText = "Downloading Whisper model..."
        startWhisperDownload(url: url, taskDescription: "whisperModel")
    }

    private func downloadAppleSpeechAssets(locale: AppleSpeechLocale) {
        guard !isDownloading else { return }
        guard #available(iOS 26.0, *) else {
            setDownloadError(AppleSpeechTranscriptionError.transcriptionUnavailable.localizedDescription)
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadStatusText = "Preparing speech model..."
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
                self.downloadStatusText = "Ready!"
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
        activeWhisperDownloadIncludesModel = false
        coreMLEncoderInstallTask?.cancel()
        coreMLEncoderInstallTask = nil
        speechAssetDownloadTask?.cancel()
        speechAssetDownloadTask = nil
        isDownloading = false
        downloadProgress = 0
        downloadStatusText = "Preparing model..."
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
        guard modelMutationIsAllowed() else { return }
        switch currentTranscriptionModel.backend {
        case .whisper:
            if FileManager.default.fileExists(atPath: whisperModelURL.path) {
                do {
                    try FileManager.default.removeItem(atPath: whisperModelURL.path)
                } catch {
                    setDownloadError(String(localized: "Error deleting model") + ": \(error.localizedDescription)")
                    return
                }
            }
            guard deleteCoreMLEncoderIfUnused(for: currentTranscriptionModel.whisperModelSize) else {
                return
            }
            isModelReady = false
            downloadError = nil
            Task {
                await WhisperModelService.shared.invalidateAndUnload()
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
        guard modelMutationIsAllowed() else { return }
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
        guard modelMutationIsAllowed() else { return }
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
        for encoderName in Set(WhisperModelSize.allCases.map(\.coreMLEncoderDirectoryName)) {
            let encoderURL = documentsPath.appendingPathComponent(encoderName)
            if FileManager.default.fileExists(atPath: encoderURL.path) {
                do {
                    try FileManager.default.removeItem(at: encoderURL)
                } catch {
                    setDownloadError(String(localized: "Error deleting model") + ": \(error.localizedDescription)")
                    return
                }
            }
        }
        isModelReady = false
        Task {
            await WhisperModelService.shared.invalidateAndUnload()
        }
    }

    private struct WhisperReadiness {
        let modelExists: Bool
        let encoderExists: Bool

        var isReady: Bool {
            modelExists && encoderExists
        }
    }

    private func whisperReadiness(for size: WhisperModelSize) -> WhisperReadiness {
        WhisperReadiness(
            modelExists: FileManager.default.fileExists(atPath: whisperModelURL(for: size).path),
            encoderExists: FileManager.default.fileExists(atPath: whisperCoreMLEncoderURL(for: size).path)
        )
    }

    private func whisperModelURL(for size: WhisperModelSize) -> URL {
        documentsURL.appendingPathComponent(size.fileName)
    }

    private func whisperCoreMLEncoderURL(for size: WhisperModelSize) -> URL {
        documentsURL.appendingPathComponent(size.coreMLEncoderDirectoryName)
    }

    func scheduleWhisperSessionStartIfNeeded() {
        guard usesWhisperBackend, currentWhisperModelIsReady(),
              let size = currentTranscriptionModel.whisperModelSize else { return }
        let modelPath = modelPath
        let encoderPath = FileManager.default.fileExists(atPath: coreMLEncoderPath) ? coreMLEncoderPath : nil
        let useFlashAttention = AppSettings.shared.useFlashAttention
        Task {
            await WhisperModelService.shared.startSession(
                modelPath: modelPath,
                encoderPath: encoderPath,
                useFlashAttention: useFlashAttention,
                coreMLMelBinCount: size.coreMLMelBinCount
            )
        }
    }

    private func startWhisperDownload(url: URL, taskDescription: String) {
        let configuration = URLSessionConfiguration.default
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        modelDownloadSession = session

        downloadTask = session.downloadTask(with: url)
        downloadTask?.taskDescription = taskDescription
        downloadTask?.resume()
    }

    private func startWhisperCoreMLEncoderDownload(size: WhisperModelSize) {
        guard let url = size.coreMLEncoderDownloadURL else {
            setDownloadError(String(localized: "Core ML encoder is not available for this model."))
            isDownloading = false
            return
        }

        downloadStatusText = "Downloading Core ML encoder..."
        startWhisperDownload(url: url, taskDescription: "coreMLEncoder")
    }

    private func finishWhisperDownloadIfReady(size: WhisperModelSize) {
        isModelReady = whisperReadiness(for: size).modelExists
        scheduleWhisperSessionStartIfNeeded()
        isDownloading = false
        downloadProgress = isModelReady ? 1 : 0
        downloadStatusText = isModelReady ? "Ready!" : "Preparing model..."
        downloadTask = nil
        activeWhisperDownloadSize = nil
        activeWhisperDownloadIncludesModel = false
    }

    private func installCoreMLEncoderArchive(from archiveURL: URL, for size: WhisperModelSize) {
        let destinationURL = whisperCoreMLEncoderURL(for: size)
        let archiveCopyURL = documentsURL.appendingPathComponent("\(size.coreMLEncoderArchiveName).download")
        do {
            if FileManager.default.fileExists(atPath: archiveCopyURL.path) {
                try FileManager.default.removeItem(at: archiveCopyURL)
            }
            try FileManager.default.moveItem(at: archiveURL, to: archiveCopyURL)
        } catch {
            setDownloadError(String(localized: "Error saving Core ML encoder") + ": \(error.localizedDescription)")
            isDownloading = false
            activeWhisperDownloadSize = nil
            activeWhisperDownloadIncludesModel = false
            return
        }

        downloadStatusText = "Installing Core ML encoder..."
        downloadProgress = max(downloadProgress, 0.95)
        coreMLEncoderInstallTask = Task.detached { [archiveCopyURL, destinationURL, size] in
            do {
                try ZipArchiveExtractor.extractMLModelCArchive(at: archiveCopyURL, to: destinationURL)
                try? FileManager.default.removeItem(at: archiveCopyURL)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    ModelManager.shared.coreMLEncoderInstallTask = nil
                    ModelManager.shared.finishWhisperDownloadIfReady(size: size)
                }
            } catch {
                try? FileManager.default.removeItem(at: archiveCopyURL)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    ModelManager.shared.coreMLEncoderInstallTask = nil
                    ModelManager.shared.setDownloadError(String(localized: "Error installing Core ML encoder") + ": \(error.localizedDescription)")
                    ModelManager.shared.isDownloading = false
                    ModelManager.shared.downloadTask = nil
                    ModelManager.shared.activeWhisperDownloadSize = nil
                    ModelManager.shared.activeWhisperDownloadIncludesModel = false
                    ModelManager.shared.isModelReady = false
                }
            }
        }
    }

    private func deleteCoreMLEncoderIfUnused(for optionalSize: WhisperModelSize?) -> Bool {
        guard let size = optionalSize else { return true }
        let encoderURL = whisperCoreMLEncoderURL(for: size)
        let isUsedByAnotherInstalledModel = WhisperModelSize.allCases.contains { otherSize in
            otherSize != size &&
            otherSize.coreMLEncoderDirectoryName == size.coreMLEncoderDirectoryName &&
            FileManager.default.fileExists(atPath: whisperModelURL(for: otherSize).path)
        }

        guard !isUsedByAnotherInstalledModel,
              FileManager.default.fileExists(atPath: encoderURL.path) else {
            return true
        }

        do {
            try FileManager.default.removeItem(at: encoderURL)
            return true
        } catch {
            setDownloadError(String(localized: "Error deleting model") + ": \(error.localizedDescription)")
            return false
        }
    }

    private func setDownloadError(_ message: String) {
        downloadError = message
        AppLogger.error(message, context: "ModelManager")
    }

    private func modelMutationIsAllowed() -> Bool {
        guard !isTranscriptionInProgress else {
            setDownloadError(String(localized: "Please wait until transcription finishes before changing or deleting models."))
            return false
        }
        return true
    }

    private func setVADDownloadError(_ message: String) {
        vadDownloadError = message
        AppLogger.error(message, context: "ModelManager")
    }
}

extension ModelManager: @preconcurrency URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if downloadTask.taskDescription == "vadModel" {
            vadDownloadProgress = progress
        } else if downloadTask.taskDescription == "whisperModel" && activeWhisperDownloadIncludesModel {
            downloadProgress = progress * 0.5
        } else if downloadTask.taskDescription == "coreMLEncoder" && activeWhisperDownloadIncludesModel {
            downloadProgress = 0.5 + progress * 0.5
        } else {
            downloadProgress = progress
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let isVADModelDownload = downloadTask.taskDescription == "vadModel"
            let isCoreMLEncoderDownload = downloadTask.taskDescription == "coreMLEncoder"
            let destinationURL: URL
            if isVADModelDownload {
                destinationURL = vadModelFileURL
            } else if isCoreMLEncoderDownload {
                guard let whisperSize = activeWhisperDownloadSize else {
                    setDownloadError(String(localized: "Downloaded model target was lost. Please download the model again."))
                    isDownloading = false
                    return
                }
                installCoreMLEncoderArchive(from: location, for: whisperSize)
                return
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
                guard let whisperSize = activeWhisperDownloadSize else {
                    setDownloadError(String(localized: "Downloaded model target was lost. Please download the model again."))
                    isDownloading = false
                    return
                }
                if FileManager.default.fileExists(atPath: whisperCoreMLEncoderURL(for: whisperSize).path) {
                    finishWhisperDownloadIfReady(size: whisperSize)
                } else {
                    startWhisperCoreMLEncoderDownload(size: whisperSize)
                }
            }
        } catch {
            if downloadTask.taskDescription == "vadModel" {
                setVADDownloadError(String(localized: "Error saving VAD model") + ": \(error.localizedDescription)")
                isVADDownloading = false
            } else {
                setDownloadError(String(localized: "Error saving model file") + ": \(error.localizedDescription)")
                isDownloading = false
                activeWhisperDownloadSize = nil
                activeWhisperDownloadIncludesModel = false
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
                    activeWhisperDownloadIncludesModel = false
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
                activeWhisperDownloadIncludesModel = false
            }
        }
    }
}
