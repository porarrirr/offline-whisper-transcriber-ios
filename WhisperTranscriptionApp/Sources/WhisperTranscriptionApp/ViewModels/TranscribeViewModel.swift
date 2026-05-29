import Foundation
import Speech
import SwiftData
import UIKit

@MainActor
class TranscribeViewModel: ObservableObject {
    @Published var isProcessing = false
    @Published var transcriptionResult: String = ""
    @Published var transcriptionSegments: [TranscriptionSegment] = []
    @Published var transcriptionLanguage: String?
    @Published var transcriptionTitle: String = ""
    @Published var transcriptionDuration: Double = 0
    @Published var errorMessage: String?
    @Published var showResult = false
    @Published var transcriptionProgress: Double = 0
    @Published var processingStatusText: String = ""
    @Published var usesDeterminateProgress = true
    @Published var liveState: LiveTranscriptionState = .idle
    @Published var liveElapsedTime: TimeInterval = 0
    @Published var liveAudioLevel: Float = -80
    @Published var liveFinalizedText: String = ""
    @Published var liveVolatileText: String = ""
    @Published var liveSegments: [TranscriptionSegment] = []
    @Published var liveRecordingURL: URL?
    
    private let modelManager = ModelManager.shared
    private let settings = AppSettings.shared
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionTaskID: UUID?
    private var liveTask: Task<Void, Never>?

    func startRecording(recordingService: RecordingService, requiresTranscriptionReadiness: Bool = true) {
        if requiresTranscriptionReadiness, let readinessError = modelManager.currentTranscriptionReadinessError() {
            setError(readinessError)
            return
        }
        transcriptionResult = ""
        transcriptionSegments = []
        transcriptionLanguage = nil
        transcriptionTitle = ""
        transcriptionDuration = 0
        errorMessage = nil
        transcriptionProgress = 0
        recordingService.startRecording()
    }
    
    func stopRecordingAndTranscribe(recordingService: RecordingService, modelContext: ModelContext) {
        startTranscriptionTask {
            await self.stopRecordingAndTranscribeAsync(recordingService: recordingService, modelContext: modelContext)
        }
    }

    func transcribeInterruptedRecording(recordingService: RecordingService, modelContext: ModelContext) {
        startTranscriptionTask {
            await self.transcribeInterruptedRecordingAsync(recordingService: recordingService, modelContext: modelContext)
        }
    }

    func startLiveTranscription(recordingService: RecordingService) {
        guard !isProcessing else { return }
        if let readinessError = modelManager.currentTranscriptionReadinessError() {
            setError(readinessError)
            return
        }
        recordingService.startLiveTranscription()
    }

    func stopLiveTranscription(recordingService: RecordingService) {
        liveTask?.cancel()
        liveTask = Task { @MainActor in
            await recordingService.stopLiveTranscription()
        }
    }

    private func stopRecordingAndTranscribeAsync(recordingService: RecordingService, modelContext: ModelContext) async {
        let recordingDuration = recordingService.currentTime
        let recordingURL: URL
        do {
            recordingURL = try await recordingService.stopRecording()
        } catch {
            setError(error.localizedDescription)
            return
        }

        let record: TranscriptionRecord
        do {
            record = try saveRecordingRecord(url: recordingURL, duration: recordingDuration, modelContext: modelContext)
        } catch {
            setError(error.localizedDescription)
            return
        }

        await transcribeAudio(url: recordingURL, sourceType: .recording, modelContext: modelContext, updating: record)
    }

    private func transcribeInterruptedRecordingAsync(recordingService: RecordingService, modelContext: ModelContext) async {
        let recordingDuration = recordingService.currentTime
        let recordingURL: URL
        do {
            recordingURL = try await recordingService.consumeInterruptedRecording()
        } catch {
            setError(error.localizedDescription)
            return
        }

        let record: TranscriptionRecord
        do {
            record = try saveRecordingRecord(url: recordingURL, duration: recordingDuration, modelContext: modelContext)
        } catch {
            setError(error.localizedDescription)
            return
        }

        await transcribeAudio(url: recordingURL, sourceType: .recording, modelContext: modelContext, updating: record)
    }
    
    func transcribeFile(url: URL, modelContext: ModelContext, cleanupAfterProcessing: Bool = false) {
        if let readinessError = modelManager.currentTranscriptionReadinessError() {
            setError(readinessError)
            if cleanupAfterProcessing {
                removeTemporaryInput(url: url)
            }
            return
        }
        startTranscriptionTask {
            await self.transcribeAudio(
                url: url,
                sourceType: .file,
                modelContext: modelContext,
                cleanupAfterProcessing: cleanupAfterProcessing
            )
        }
    }

    func transcribeRecord(_ record: TranscriptionRecord, modelContext: ModelContext) {
        startTranscriptionTask {
            await self.transcribeRecordAsync(record, modelContext: modelContext)
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        Task {
            await WhisperModelService.shared.cancelLoad()
        }
    }

    func cancelLiveTranscription(recordingService: RecordingService) {
        liveTask?.cancel()
        liveTask = Task { @MainActor in
            await recordingService.cancelLiveTranscription()
        }
    }

    private func transcribeRecordAsync(_ record: TranscriptionRecord, modelContext: ModelContext) async {
        guard let audioFilePath = record.audioFilePath else {
            setError(String(localized: "No audio file is attached to this history item."))
            return
        }

        let audioURL = URL(fileURLWithPath: audioFilePath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            setError(String(localized: "The audio file for this history item could not be found."))
            return
        }

        await transcribeAudio(url: audioURL, sourceType: record.sourceTypeEnum, modelContext: modelContext, updating: record)
    }
    
    private func transcribeAudio(
        url: URL,
        sourceType: TranscriptionRecord.SourceType,
        modelContext: ModelContext,
        updating existingRecord: TranscriptionRecord? = nil,
        cleanupAfterProcessing: Bool = false
    ) async {
        errorMessage = nil
        transcriptionResult = ""
        transcriptionSegments = []
        transcriptionLanguage = nil
        transcriptionTitle = ""
        transcriptionDuration = 0

        isProcessing = true
        showResult = false
        transcriptionProgress = 0
        usesDeterminateProgress = settings.usesWhisperBackend
        processingStatusText = settings.usesAppleSpeechBackend
            ? String(localized: "Preparing speech model...")
            : String(localized: "Converting...")
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        defer {
            isProcessing = false
            transcriptionProgress = 0
            usesDeterminateProgress = true
            processingStatusText = ""
            UIApplication.shared.isIdleTimerDisabled = false
            if cleanupAfterProcessing {
                removeTemporaryInput(url: url)
            }
        }

        do {
            AppLogger.info(
                "Transcription started: source=\(sourceType), file=\(url.lastPathComponent), model=\(settings.selectedTranscriptionModel.storageKey), language=\(settings.selectedLanguage), translate=\(settings.translateToEnglish), useVAD=\(settings.useVAD)",
                context: "TranscribeViewModel"
            )

            let duration = try await AudioConverter.shared.getAudioDuration(url: url)
            let result: ChunkedTranscriptionResult

            switch settings.selectedTranscriptionModel.backend {
            case .whisper:
                guard modelManager.currentWhisperModelIsReady() else {
                    setError(modelManager.whisperReadinessMessage())
                    throw TranscriptionAborted()
                }
                result = try await transcribeWithWhisper(url: url, duration: duration)
            case .appleSpeech(let locale):
                result = try await transcribeWithAppleSpeech(url: url, locale: locale)
            }

            AppLogger.info(
                "文字起こしが完了しました: file=\(url.lastPathComponent), textLength=\(result.text.count), segments=\(result.segments.count), language=\(result.language ?? "unknown")",
                context: "TranscribeViewModel"
            )
            transcriptionProgress = 1
            transcriptionResult = result.text
            transcriptionSegments = result.segments
            transcriptionLanguage = result.language

            let savedDuration = max(duration, result.processedDuration)
            let record = existingRecord ?? TranscriptionRecord(
                title: TranscriptionRecord.defaultTitle(for: Date()),
                text: "",
                sourceType: sourceType,
                audioFilePath: sourceType == .recording ? url.path : nil,
                duration: savedDuration
            )
            if existingRecord == nil {
                modelContext.insert(record)
            }
            record.updateTranscription(
                text: result.text,
                duration: savedDuration,
                segments: result.segments,
                language: result.language
            )
            transcriptionTitle = record.displayTitle
            transcriptionDuration = savedDuration
            showResult = true
            do {
                try modelContext.save()
            } catch {
                if existingRecord == nil {
                    modelContext.delete(record)
                }
                setError(String(localized: "Failed to save history") + ": \(error.localizedDescription)")
            }

            if settings.autoDeleteRecordings && sourceType == .recording {
                scheduleRecordingDeletion(url: url)
            }
        } catch is TranscriptionAborted {
            return
        } catch is CancellationError {
            AppLogger.info(
                "文字起こしがキャンセルされました: file=\(url.lastPathComponent), source=\(sourceType)",
                context: "TranscribeViewModel"
            )
        } catch {
            AppLogger.error(
                "Exception during transcription pipeline: file=\(url.lastPathComponent), source=\(sourceType)",
                context: "TranscribeViewModel",
                error: error
            )
            setError(error.localizedDescription)
        }
    }
    
    private func transcribeWithWhisper(url: URL, duration: TimeInterval) async throws -> ChunkedTranscriptionResult {
        processingStatusText = String(localized: "Loading model...")
        usesDeterminateProgress = false

        do {
            try await WhisperModelService.shared.ensureModelLoaded(
                path: modelManager.modelPath,
                useFlashAttention: settings.useFlashAttention
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            setError((error as? LocalizedError)?.errorDescription ?? String(localized: "Failed to load model"))
            throw TranscriptionAborted()
        }

        processingStatusText = String(localized: "Converting...")
        usesDeterminateProgress = true

        let language = settings.selectedLanguage == "auto" ? "" : settings.selectedLanguage
        let useVAD = settings.useVAD
        if useVAD && !modelManager.isVADModelReady {
            setError(String(localized: "VAD model is not ready. Please download the VAD model from settings."))
            throw TranscriptionAborted()
        }

        return try await WhisperModelService.shared.transcribe(
            inputURL: url,
            language: language,
            translate: settings.translateToEnglish,
            prompt: settings.promptText,
            useVAD: useVAD,
            vadModelPath: useVAD ? modelManager.vadModelPath : nil
        ) { [weak self] chunk, progress in
            let totalDuration = chunk.totalDuration > 0 ? chunk.totalDuration : max(duration, chunk.startTime + chunk.duration)
            let progressStart = totalDuration > 0 ? min(chunk.startTime / totalDuration, 0.99) : 0
            let progressSpan = totalDuration > 0 ? max(chunk.duration / totalDuration, 0.01) : 0.01

            Task { @MainActor in
                self?.processingStatusText = String(localized: "Transcribing...")
                guard let self else { return }
                let nextProgress = min(progressStart + progress * progressSpan, 0.99)
                self.transcriptionProgress = max(self.transcriptionProgress, nextProgress)
            }
        }
    }

    private func transcribeWithAppleSpeech(url: URL, locale: AppleSpeechLocale) async throws -> ChunkedTranscriptionResult {
        guard #available(iOS 26.0, *) else {
            throw AppleSpeechTranscriptionError.transcriptionUnavailable
        }

        processingStatusText = String(localized: "Preparing speech model...")
        return try await AppleSpeechTranscriptionService().transcribe(
            inputURL: url,
            locale: locale,
            includeTimestamps: false
        ) { [weak self] progress in
            Task { @MainActor in
                if progress < 0.21 {
                    self?.processingStatusText = String(localized: "Preparing speech model...")
                } else if progress < 0.41 {
                    self?.processingStatusText = String(localized: "Converting audio...")
                } else {
                    self?.processingStatusText = String(localized: "Transcribing...")
                }
                self?.transcriptionProgress = max(self?.transcriptionProgress ?? 0, min(progress, 0.99))
            }
        }
    }

    private func scheduleRecordingDeletion(url: URL) {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 7 * 24 * 60 * 60) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                AppLogger.error("Failed to automatically delete recording file", context: "TranscribeViewModel", error: error)
            }
        }
    }

    private func removeTemporaryInput(url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            AppLogger.error("Failed to remove temporary input file", context: "TranscribeViewModel", error: error)
        }
    }

    func setError(_ message: String) {
        errorMessage = message
        AppLogger.error(message, context: "TranscribeViewModel")
    }
    
    func reset() {
        transcriptionResult = ""
        transcriptionSegments = []
        transcriptionLanguage = nil
        transcriptionTitle = ""
        transcriptionDuration = 0
        showResult = false
        errorMessage = nil
        transcriptionProgress = 0
        usesDeterminateProgress = true
        processingStatusText = ""
    }

    private func applyLiveSnapshot(_ snapshot: LiveTranscriptionSnapshot) {
        liveState = snapshot.state
        liveElapsedTime = snapshot.elapsedTime
        liveAudioLevel = snapshot.audioLevel
        liveFinalizedText = snapshot.finalizedText
        liveVolatileText = snapshot.volatileText
        liveSegments = snapshot.segments
        liveRecordingURL = snapshot.recordingURL
        transcriptionResult = snapshot.finalizedText
        transcriptionSegments = snapshot.segments
        transcriptionLanguage = snapshot.language
        if let errorMessage = snapshot.errorMessage {
            self.errorMessage = errorMessage
        }
    }

    private func resetLiveSnapshot() {
        liveState = .idle
        liveElapsedTime = 0
        liveAudioLevel = -80
        liveFinalizedText = ""
        liveVolatileText = ""
        liveSegments = []
        liveRecordingURL = nil
        errorMessage = nil
    }

    private func setLiveFailure(_ message: String) {
        liveState = .failed
        errorMessage = message
        AppLogger.error(message, context: "TranscribeViewModel")
    }

    private func saveLiveTranscription(_ snapshot: LiveTranscriptionSnapshot, modelContext: ModelContext) throws {
        guard let recordingURL = snapshot.recordingURL else {
            throw LiveTranscriptionError.recordingFileMissing
        }

        let text = snapshot.finalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw LiveTranscriptionError.emptyTranscription
        }

        let createdAt = Date()
        let record = TranscriptionRecord(
            title: TranscriptionRecord.defaultTitle(for: createdAt),
            text: text,
            sourceType: .recording,
            audioFilePath: recordingURL.path,
            duration: snapshot.elapsedTime,
            createdAt: createdAt,
            segments: snapshot.segments,
            language: snapshot.language
        )
        modelContext.insert(record)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(record)
            throw TranscriptionPipelineError.historySaveFailed(error.localizedDescription)
        }

        if settings.autoDeleteRecordings {
            scheduleRecordingDeletion(url: recordingURL)
        }
    }

    private func startTranscriptionTask(_ operation: @escaping @MainActor () async -> Void) {
        transcriptionTask?.cancel()
        let taskID = UUID()
        transcriptionTaskID = taskID
        transcriptionTask = Task { @MainActor in
            await operation()
            if transcriptionTaskID == taskID {
                transcriptionTask = nil
                transcriptionTaskID = nil
            }
        }
    }

    private func saveRecordingRecord(url: URL, duration: TimeInterval, modelContext: ModelContext) throws -> TranscriptionRecord {
        let createdAt = Date()
        let record = TranscriptionRecord(
            title: TranscriptionRecord.defaultTitle(for: createdAt),
            text: "",
            sourceType: .recording,
            audioFilePath: url.path,
            duration: duration,
            createdAt: createdAt
        )
        modelContext.insert(record)
        do {
            try modelContext.save()
            return record
        } catch {
            modelContext.delete(record)
            throw TranscriptionPipelineError.historySaveFailed(error.localizedDescription)
        }
    }
}

private struct TranscriptionAborted: Error {}

private enum TranscriptionPipelineError: LocalizedError {
    case historySaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .historySaveFailed(let message):
            return String(localized: "Failed to save history") + ": \(message)"
        }
    }
}
