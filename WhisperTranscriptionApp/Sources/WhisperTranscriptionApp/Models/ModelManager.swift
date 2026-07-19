import Combine
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
    @Published var isWaitingForSpeechAsset = false
    @Published private(set) var speechAssetSnapshot = SpeechAssetSnapshot()
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
    private let speechAssetCoordinator = SpeechAssetCoordinator.shared
    private var cancellables = Set<AnyCancellable>()
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
        switch readiness.modelFileStatus {
        case .valid:
            return String(localized: "Model Ready")
        case .missing:
            return String(localized: "Please download model")
        case .invalid:
            return String(localized: "Downloaded model file is incomplete. Download the model again.")
        }
    }

    func whisperAccelerationWarningMessage() -> String? {
        guard let size = currentTranscriptionModel.whisperModelSize else { return nil }
        let readiness = whisperReadiness(for: size)
        guard readiness.modelExists else { return nil }
        let mode = CoreMLCompatibilityPolicy.accelerationMode(hasVerifiedEncoder: readiness.encoderExists)
        guard case .metal = mode else { return nil }
        return mode.description
    }

    var canDownloadCoreMLEncoder: Bool {
        guard CoreMLCompatibilityPolicy.currentOperatingSystemAllowsCoreML,
              let size = currentTranscriptionModel.whisperModelSize,
              size.coreMLEncoderArtifact != nil else { return false }
        return !whisperReadiness(for: size).encoderExists
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
            return "\(speechAssetSnapshot.statusTitle)\n\(speechAssetSnapshot.statusDetail)"
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
        if let locale = currentTranscriptionModel.appleSpeechLocale {
            speechAssetCoordinator.markUsed(locale: locale)
        }
    }

    func endTranscriptionOperation() {
        transcriptionOperationCount = max(0, transcriptionOperationCount - 1)
        isTranscriptionInProgress = transcriptionOperationCount > 0
    }

    func recheckSpeechAssets() {
        speechAssetCoordinator.recheck(locale: currentTranscriptionModel.appleSpeechLocale)
    }

    func retrySpeechAssetPreparation() {
        speechAssetCoordinator.retry()
    }

    func prepareSpeechAsset(locale: AppleSpeechLocale) {
        guard modelMutationIsAllowed() else { return }
        speechAssetCoordinator.prepare(locale: locale)
    }

    func useSpeechAsset(locale: AppleSpeechLocale) {
        guard modelMutationIsAllowed() else { return }
        switchModel(model: .appleSpeech(locale))
        if !isSpeechAssetReady(locale: locale) {
            speechAssetCoordinator.prepare(locale: locale)
        }
    }

    func releaseSpeechAssetReservation(_ reservedLocaleIdentifier: String) async -> Bool {
        guard modelMutationIsAllowed() else { return false }
        return await speechAssetCoordinator.release(reservedLocaleIdentifier: reservedLocaleIdentifier)
    }

    func replaceSpeechAssetReservation(
        releasing reservedLocaleIdentifier: String,
        with locale: AppleSpeechLocale
    ) async -> Bool {
        guard modelMutationIsAllowed() else { return false }
        guard await speechAssetCoordinator.release(
            reservedLocaleIdentifier: reservedLocaleIdentifier
        ) else { return false }

        switchModel(model: .appleSpeech(locale))
        speechAssetCoordinator.prepare(locale: locale)
        return true
    }

    func availableTranscriptionModels() -> [TranscriptionModel] {
        let speechModels = speechAssetSnapshot.localeRecords
            .filter { $0.isInstalled && $0.isReserved }
            .sorted(by: Self.localeRecordAlphabeticalOrder)
            .map { TranscriptionModel.appleSpeech($0.locale) }

        let whisperModels: [TranscriptionModel] = [
            .whisper(.tiny),
            .whisper(.smallQ5_1),
            .whisper(.largeV3TurboQ5_0),
        ].filter { model in
            guard let size = model.whisperModelSize else { return false }
            return whisperReadiness(for: size).isReady
        }

        return speechModels + whisperModels
    }

    func speechAssetDiagnosticReport() -> String {
        speechAssetCoordinator.diagnosticReport()
    }

    func handleBecameActive() {
        speechAssetCoordinator.handleBecameActive(
            selectedLocale: currentTranscriptionModel.appleSpeechLocale
        )
    }

    private override init() {
        currentTranscriptionModel = AppSettings.shared.selectedTranscriptionModel
        super.init()
        bindSpeechAssetCoordinator()
        speechAssetCoordinator.restorePersistedState(
            selectedLocale: currentTranscriptionModel.appleSpeechLocale
        )
        ensureModelAvailability()
        checkVADModelAvailability()
    }

    private func bindSpeechAssetCoordinator() {
        speechAssetCoordinator.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.speechAssetSnapshot = snapshot
                guard let selectedLocale = self.currentTranscriptionModel.appleSpeechLocale else { return }

                let selectedIdentifier = SpeechAssetLocaleIdentifier.canonical(selectedLocale.localeIdentifier)
                let selectedRecord = snapshot.localeRecords.first {
                    SpeechAssetLocaleIdentifier.canonical($0.localeIdentifier) == selectedIdentifier
                }
                self.isModelReady = selectedRecord?.isInstalled == true && selectedRecord?.isReserved == true

                let activeIdentifier = (snapshot.normalizedLocaleIdentifier ?? snapshot.requestedLocaleIdentifier)
                    .map(SpeechAssetLocaleIdentifier.canonical)
                let activeIsSelected = activeIdentifier == selectedIdentifier
                self.isDownloading = snapshot.isOperationActive && activeIsSelected
                self.isWaitingForSpeechAsset = activeIsSelected && {
                    if case .systemManagedPending = snapshot.state { return true }
                    return false
                }()
                self.downloadProgress = activeIsSelected ? (snapshot.measuredProgress ?? (snapshot.isInstalled ? 1 : 0)) : 0
                self.downloadStatusText = snapshot.statusTitle

                switch snapshot.state {
                case .failed, .insufficientStorage, .reservationLimitReached, .unsupported:
                    self.downloadError = activeIsSelected ? snapshot.statusDetail : nil
                default:
                    self.downloadError = nil
                }
            }
            .store(in: &cancellables)
    }

    private func isSpeechAssetReady(locale: AppleSpeechLocale) -> Bool {
        let identifier = SpeechAssetLocaleIdentifier.canonical(locale.localeIdentifier)
        return speechAssetSnapshot.localeRecords.contains {
            SpeechAssetLocaleIdentifier.canonical($0.localeIdentifier) == identifier
                && $0.isInstalled
                && $0.isReserved
        }
    }

    private static func localeRecordAlphabeticalOrder(
        _ lhs: SpeechLocaleRecord,
        _ rhs: SpeechLocaleRecord
    ) -> Bool {
        let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if comparison == .orderedSame {
            return lhs.localeIdentifier.localizedCaseInsensitiveCompare(rhs.localeIdentifier) == .orderedAscending
        }
        return comparison == .orderedAscending
    }

    func checkModelAvailability() {
        ensureModelAvailability()
    }

    func ensureModelAvailability() {
        Task { @MainActor in
            await refreshModelReadyState(autoInstallSystemAssets: false)
        }
    }

    func refreshModelReadyState(autoInstallSystemAssets: Bool = false) async {
        let targetModel = currentTranscriptionModel
        switch targetModel.backend {
        case .whisper:
            guard currentTranscriptionModel == targetModel else { return }
            isModelReady = currentWhisperModelIsReady()
        case .appleSpeech(let locale):
            guard #available(iOS 26.0, *) else {
                isModelReady = false
                return
            }
            let ready = await speechAssetCoordinator.isReady(locale: locale)
            guard currentTranscriptionModel == targetModel else { return }
            isModelReady = ready
            speechAssetCoordinator.configureSelectedLocale(locale)
            if !ready && autoInstallSystemAssets {
                downloadAppleSpeechAssets(locale: locale)
            }
        }
    }

    func checkVADModelAvailability() {
        let exists = FileManager.default.fileExists(atPath: vadModelPath)
        isVADModelReady = exists
    }

    func switchModel(model: TranscriptionModel) {
        guard model != currentTranscriptionModel else {
            if AppSettings.shared.selectedTranscriptionModel != model {
                AppSettings.shared.selectedTranscriptionModel = model
            }
            ensureModelAvailability()
            return
        }
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
        if speechAssetSnapshot.isOperationActive {
            speechAssetCoordinator.cancel()
        }
        isWaitingForSpeechAsset = false
        currentTranscriptionModel = model
        AppSettings.shared.selectedTranscriptionModel = model
        isModelReady = false
        Task {
            await WhisperModelService.shared.invalidateAndUnload()
        }
        isDownloading = false
        downloadProgress = 0
        downloadStatusText = "Preparing model..."
        downloadError = nil
        Task { @MainActor in
            await refreshModelReadyState(autoInstallSystemAssets: false)
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
        let includeCoreML = CoreMLCompatibilityPolicy.currentOperatingSystemAllowsCoreML
            && size.coreMLEncoderArtifact != nil
        guard !readiness.isReady else {
            isModelReady = true
            downloadProgress = 1
            downloadError = nil
            scheduleWhisperSessionStartIfNeeded()
            return
        }

        let requiredBytes = size.requiredDownloadBytes(
            modelExists: readiness.modelExists,
            encoderExists: readiness.encoderExists,
            includeCoreML: includeCoreML
        )
        do {
            try DiskSpaceChecker.ensureAvailable(at: documentsURL, requiredBytes: requiredBytes)
        } catch {
            if includeCoreML && !readiness.encoderExists {
                WhisperRuntimeStatus.shared.applySnapshot(
                    isLoadingModel: false,
                    accelerationMode: .metal(reason: .insufficientStorage)
                )
            }
            setDownloadError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadStatusText = "Preparing model..."
        downloadError = nil
        activeWhisperDownloadSize = size
        activeWhisperDownloadIncludesModel = !readiness.modelExists

        if readiness.modelExists && includeCoreML {
            startWhisperCoreMLEncoderDownload(size: size)
            return
        }

        if readiness.modelExists {
            finishWhisperDownloadIfReady(size: size)
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
        guard #available(iOS 26.0, *) else {
            setDownloadError(AppleSpeechTranscriptionError.transcriptionUnavailable.localizedDescription)
            return
        }
        downloadError = nil
        speechAssetCoordinator.prepare(locale: locale)
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
        if currentTranscriptionModel.backend.isAppleSpeech {
            speechAssetCoordinator.cancel()
            return
        }
        downloadTask?.cancel()
        downloadTask = nil
        activeWhisperDownloadSize = nil
        activeWhisperDownloadIncludesModel = false
        coreMLEncoderInstallTask?.cancel()
        coreMLEncoderInstallTask = nil
        isWaitingForSpeechAsset = false
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
                } else if let size = attributes[.size] as? NSNumber {
                    let formatter = ByteCountFormatter()
                    formatter.countStyle = .file
                    return formatter.string(fromByteCount: size.int64Value)
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
            guard let record = speechAssetSnapshot.localeRecords.first(where: {
                SpeechAssetLocaleIdentifier.canonical($0.localeIdentifier)
                    == SpeechAssetLocaleIdentifier.canonical(locale.localeIdentifier)
            }), let reservedLocaleIdentifier = record.reservedLocaleIdentifier else { return }
            Task { @MainActor in
                _ = await speechAssetCoordinator.release(reservedLocaleIdentifier: reservedLocaleIdentifier)
                isModelReady = false
                downloadError = nil
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
            // Remove pre-manifest encoders as user-requested data deletion, never as migration fallback.
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
        let versionedEncodersURL = documentsPath.appendingPathComponent("CoreMLEncoders", isDirectory: true)
        if FileManager.default.fileExists(atPath: versionedEncodersURL.path) {
            do {
                try FileManager.default.removeItem(at: versionedEncodersURL)
            } catch {
                setDownloadError(String(localized: "Error deleting model") + ": \(error.localizedDescription)")
                return
            }
        }
        isModelReady = false
        Task {
            await WhisperModelService.shared.invalidateAndUnload()
        }
    }

    private struct WhisperReadiness {
        let modelFileStatus: WhisperModelFileStatus
        let encoderExists: Bool
        let encoderRequired: Bool

        var modelExists: Bool {
            modelFileStatus == .valid
        }

        var isReady: Bool {
            modelExists && (!encoderRequired || encoderExists)
        }
    }

    private enum WhisperModelFileStatus: Equatable {
        case missing
        case invalid(actualSize: Int64)
        case valid
    }

    private func whisperReadiness(for size: WhisperModelSize) -> WhisperReadiness {
        let artifact = size.coreMLEncoderArtifact
        let encoderURL = whisperCoreMLEncoderURL(for: size)
        return WhisperReadiness(
            modelFileStatus: whisperModelFileStatus(for: size, at: whisperModelURL(for: size)),
            encoderExists: artifact.map {
                CoreMLEncoderVerifier.verifyInstalledModel(at: encoderURL, expectedSHA256: $0.sha256)
            } ?? false,
            encoderRequired: CoreMLCompatibilityPolicy.currentOperatingSystemAllowsCoreML && artifact != nil
        )
    }

    private func whisperModelFileStatus(for size: WhisperModelSize, at url: URL) -> WhisperModelFileStatus {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            return size.isValidModelFileSize(byteCount) ? .valid : .invalid(actualSize: byteCount)
        } catch {
            AppLogger.error("Failed to inspect model file", context: "ModelManager", error: error)
            return .invalid(actualSize: -1)
        }
    }

    private func whisperModelURL(for size: WhisperModelSize) -> URL {
        documentsURL.appendingPathComponent(size.fileName)
    }

    private func whisperCoreMLEncoderURL(for size: WhisperModelSize) -> URL {
        documentsURL
            .appendingPathComponent("CoreMLEncoders", isDirectory: true)
            .appendingPathComponent(CoreMLEncoderManifest.current.version, isDirectory: true)
            .appendingPathComponent(size.coreMLEncoderDirectoryName, isDirectory: true)
    }

    func scheduleWhisperSessionStartIfNeeded() {
        guard usesWhisperBackend, currentWhisperModelIsReady(),
              let size = currentTranscriptionModel.whisperModelSize else { return }
        let modelPath = modelPath
        let readiness = whisperReadiness(for: size)
        let encoderPath = readiness.encoderExists ? coreMLEncoderPath : nil
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
        guard CoreMLCompatibilityPolicy.currentOperatingSystemAllowsCoreML else {
            finishWhisperDownloadIfReady(size: size)
            return
        }
        guard let artifact = size.coreMLEncoderArtifact else {
            AppLogger.info(
                "No verified Core ML release artifact for \(size.coreMLModelID); continuing with Metal",
                context: "ModelManager"
            )
            finishWhisperDownloadIfReady(size: size)
            return
        }

        downloadStatusText = "Downloading Core ML encoder..."
        startWhisperDownload(url: artifact.url, taskDescription: "coreMLEncoder")
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
        guard let artifact = size.coreMLEncoderArtifact else {
            setDownloadError(String(localized: "Core ML encoder release metadata is unavailable."))
            isDownloading = false
            return
        }
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
        coreMLEncoderInstallTask = Task.detached { [archiveCopyURL, destinationURL, size, artifact] in
            do {
                try CoreMLEncoderVerifier.verifyArchive(
                    at: archiveCopyURL,
                    expectedSHA256: artifact.sha256,
                    expectedBytes: artifact.archiveBytes
                )
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try ZipArchiveExtractor.extractMLModelCArchive(at: archiveCopyURL, to: destinationURL)
                try CoreMLEncoderVerifier.markInstalledModel(
                    at: destinationURL,
                    sha256: artifact.sha256,
                    expectedBytes: artifact.installedBytes
                )
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
                    WhisperRuntimeStatus.shared.applySnapshot(
                        isLoadingModel: false,
                        accelerationMode: .metal(reason: .encoderInvalid)
                    )
                    ModelManager.shared.coreMLEncoderInstallTask = nil
                    ModelManager.shared.setDownloadError(String(localized: "Error installing Core ML encoder") + ": \(error.localizedDescription)")
                    ModelManager.shared.isDownloading = false
                    ModelManager.shared.downloadTask = nil
                    ModelManager.shared.activeWhisperDownloadSize = nil
                    ModelManager.shared.activeWhisperDownloadIncludesModel = false
                    ModelManager.shared.isModelReady = ModelManager.shared.whisperReadiness(for: size).modelExists
                    ModelManager.shared.downloadProgress = ModelManager.shared.isModelReady ? 1 : 0
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
            whisperModelFileStatus(for: otherSize, at: whisperModelURL(for: otherSize)) == .valid
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

    private static func userFacingMessage(for error: Error) -> String {
        guard let localizedError = error as? LocalizedError else {
            return error.localizedDescription
        }

        let description = localizedError.errorDescription ?? error.localizedDescription
        guard let recovery = localizedError.recoverySuggestion, !recovery.isEmpty else {
            return description
        }
        return "\(description)\n\(recovery)"
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

    private func validateWhisperModelDownload(at url: URL, size: WhisperModelSize) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size.isValidModelFileSize(byteCount) else {
            throw ModelDownloadValidationError.unexpectedFileSize(expected: size.modelFileSizeBytes, actual: byteCount)
        }
    }
}

private enum ModelDownloadValidationError: LocalizedError {
    case unexpectedFileSize(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .unexpectedFileSize(let expected, let actual):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return String(
                format: String(localized: "Downloaded model file size is invalid. Expected %@ but received %@. Please download the model again."),
                formatter.string(fromByteCount: expected),
                formatter.string(fromByteCount: max(0, actual))
            )
        }
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
                try validateWhisperModelDownload(at: location, size: whisperSize)
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
                if whisperReadiness(for: whisperSize).isReady {
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
