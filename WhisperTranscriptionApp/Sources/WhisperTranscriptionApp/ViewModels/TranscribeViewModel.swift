import Foundation
import SwiftData
import UIKit

@MainActor
class TranscribeViewModel: ObservableObject {
    @Published var isProcessing = false
    @Published var transcriptionResult: String = ""
    @Published var transcriptionSegments: [TranscriptionSegment] = []
    @Published var transcriptionLanguage: String?
    @Published var errorMessage: String?
    @Published var showResult = false
    @Published var transcriptionProgress: Double = 0
    @Published var processingStatusText: String = ""
    
    private let whisperContext = WhisperContext()
    private let modelManager = ModelManager.shared
    private let settings = AppSettings.shared
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionTaskID: UUID?

    func startRecording(recordingService: RecordingService) {
        releaseWhisperModel(reason: "recording started")
        transcriptionResult = ""
        transcriptionSegments = []
        transcriptionLanguage = nil
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

        guard modelManager.isModelReady else {
            if cleanupAfterProcessing {
                removeTemporaryInput(url: url)
            }
            setError(String(localized: "Model is not ready"))
            return
        }
        
        isProcessing = true
        showResult = false
        transcriptionProgress = 0
        processingStatusText = String(localized: "Converting...")
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        defer {
            isProcessing = false
            transcriptionProgress = 0
            processingStatusText = ""
            UIApplication.shared.isIdleTimerDisabled = false
            releaseWhisperModel(reason: "transcription finished")
            if cleanupAfterProcessing {
                removeTemporaryInput(url: url)
            }
        }
        
        do {
            AppLogger.info(
                "Transcription started: source=\(sourceType), file=\(url.lastPathComponent), language=\(settings.selectedLanguage), translate=\(settings.translateToEnglish), useVAD=\(settings.useVAD)",
                context: "TranscribeViewModel"
            )

            if !whisperContext.isLoaded(path: modelManager.modelPath, useFlashAttention: settings.useFlashAttention) {
                AppLogger.info("Loading Whisper model...", context: "TranscribeViewModel")
                let loaded = try await loadModelAsync()
                guard loaded else {
                    setError(whisperContext.errorMessage ?? String(localized: "Failed to load model"))
                    return
                }
                AppLogger.info("Whisper model load completed", context: "TranscribeViewModel")
            }
            
            let language = settings.selectedLanguage == "auto" ? "" : settings.selectedLanguage
            let prompt = settings.promptText
            let useVAD = settings.useVAD
            if useVAD && !modelManager.isVADModelReady {
                setError(String(localized: "VAD model is not ready. Please download the VAD model from settings."))
                return
            }

            let duration = try await AudioConverter.shared.getAudioDuration(url: url)
            let processor = TranscriptionChunkProcessor()
            let result = try await processor.transcribe(
                inputURL: url,
                whisperContext: whisperContext,
                language: language,
                translate: settings.translateToEnglish,
                prompt: prompt,
                useVAD: useVAD,
                vadModelPath: useVAD ? modelManager.vadModelPath : nil
            ) { [weak self] chunk, progress in
                let totalDuration = chunk.totalDuration > 0 ? chunk.totalDuration : max(duration, chunk.startTime + chunk.duration)
                let progressStart = totalDuration > 0 ? min(chunk.startTime / totalDuration, 0.99) : 0
                let progressSpan = totalDuration > 0 ? max(chunk.duration / totalDuration, 0.01) : 0.01

                Task { @MainActor in
                    self?.processingStatusText = String(localized: "Transcribing...")
                    self?.transcriptionProgress = min(progressStart + progress * progressSpan, 0.99)
                }
            }

            AppLogger.info(
                "文字起こしが完了しました: file=\(url.lastPathComponent), textLength=\(result.text.count), segments=\(result.segments.count), language=\(result.language ?? "unknown")",
                context: "TranscribeViewModel"
            )
            transcriptionProgress = 1
            transcriptionResult = result.text
            transcriptionSegments = result.segments
            transcriptionLanguage = result.language
            showResult = true

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
    
    private func loadModelAsync() async throws -> Bool {
        whisperContext.loadModel(
            path: modelManager.modelPath,
            useFlashAttention: settings.useFlashAttention
        )

        while true {
            try Task.checkCancellation()
            if whisperContext.isModelLoaded || whisperContext.errorMessage != nil {
                return whisperContext.isModelLoaded
            }
            try await Task.sleep(nanoseconds: 500_000_000)
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

    private func releaseWhisperModel(reason: String) {
        guard whisperContext.isModelLoaded else { return }
        whisperContext.unloadModel()
        AppLogger.info("Whisper model released: reason=\(reason)", context: "TranscribeViewModel")
    }

    func setError(_ message: String) {
        errorMessage = message
        AppLogger.error(message, context: "TranscribeViewModel")
    }
    
    func reset() {
        transcriptionResult = ""
        transcriptionSegments = []
        transcriptionLanguage = nil
        showResult = false
        errorMessage = nil
        transcriptionProgress = 0
        processingStatusText = ""
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

private enum TranscriptionPipelineError: LocalizedError {
    case historySaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .historySaveFailed(let message):
            return String(localized: "Failed to save history") + ": \(message)"
        }
    }
}
