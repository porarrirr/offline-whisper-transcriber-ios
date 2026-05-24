import Foundation
import SwiftData
import Combine
import UIKit

@MainActor
class TranscribeViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var transcriptionResult: String = ""
    @Published var transcriptionSegments: [TranscriptionSegment] = []
    @Published var transcriptionLanguage: String?
    @Published var errorMessage: String?
    @Published var recordingDuration: TimeInterval = 0
    @Published var showResult = false
    @Published var transcriptionProgress: Double = 0
    @Published var processingStatusText: String = ""
    
    private let audioRecorder = AudioRecorder()
    private let whisperContext = WhisperContext()
    private let modelManager = ModelManager.shared
    private let settings = AppSettings.shared
    private let transcriptionChunkDuration: TimeInterval = 5 * 60
    private var cancellables = Set<AnyCancellable>()
    
    var audioLevel: Float {
        audioRecorder.audioLevel
    }
    
    init() {
        audioRecorder.$currentTime
            .receive(on: DispatchQueue.main)
            .assign(to: &$recordingDuration)
        audioRecorder.$isRecording
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)
        audioRecorder.$recordingError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                self.setError(message)
                UIApplication.shared.isIdleTimerDisabled = false
                Task {
                    await RecordingLiveActivityManager.shared.endRecordingActivity()
                }
            }
            .store(in: &cancellables)
    }
    
    func startRecording() {
        audioRecorder.requestPermission { [weak self] granted in
            guard let self = self else { return }
            if granted {
                DispatchQueue.main.async {
                    do {
                        try self.audioRecorder.startRecording()
                        self.transcriptionResult = ""
                        self.transcriptionSegments = []
                        self.errorMessage = nil
                        self.transcriptionProgress = 0
                        Task {
                            await RecordingLiveActivityManager.shared.startRecordingActivity()
                        }
                        
                        if self.settings.keepScreenOn {
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                    } catch {
                        self.setError(error.localizedDescription)
                    }
                }
            } else {
                self.setError(String(localized: "Microphone permission is required"))
            }
        }
    }
    
    func stopRecordingAndTranscribe(modelContext: ModelContext) {
        Task {
            await stopRecordingAndTranscribeAsync(modelContext: modelContext)
        }
    }

    private func stopRecordingAndTranscribeAsync(modelContext: ModelContext) async {
        let recordingURL: URL
        do {
            recordingURL = try await audioRecorder.stopRecording()
        } catch {
            setError(error.localizedDescription)
            isRecording = false
            Task {
                await RecordingLiveActivityManager.shared.endRecordingActivity()
            }
            return
        }

        isRecording = false
        recordingDuration = audioRecorder.currentTime
        Task {
            await RecordingLiveActivityManager.shared.endRecordingActivity()
        }
        if let recordingError = audioRecorder.recordingError {
            setError(recordingError)
            return
        }
        
        Task {
            await transcribeAudio(url: recordingURL, sourceType: .recording, modelContext: modelContext)
        }
    }
    
    func transcribeFile(url: URL, modelContext: ModelContext, cleanupAfterProcessing: Bool = false) {
        Task {
            await transcribeAudio(
                url: url,
                sourceType: .file,
                modelContext: modelContext,
                cleanupAfterProcessing: cleanupAfterProcessing
            )
        }
    }
    
    private func transcribeAudio(
        url: URL,
        sourceType: TranscriptionRecord.SourceType,
        modelContext: ModelContext,
        cleanupAfterProcessing: Bool = false
    ) async {
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
            if cleanupAfterProcessing {
                removeTemporaryInput(url: url)
            }
        }
        
        do {
            AppLogger.info(
                "Transcription started: source=\(sourceType), file=\(url.lastPathComponent), language=\(settings.selectedLanguage), translate=\(settings.translateToEnglish), useVAD=\(settings.useVAD)",
                context: "TranscribeViewModel"
            )

            if whisperContext.isModelLoaded == false {
                AppLogger.info("Loading Whisper model...", context: "TranscribeViewModel")
                let loaded = await loadModelAsync()
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
            var textParts: [String] = []
            var combinedSegments: [TranscriptionSegment] = []
            var detectedLanguage: String?
            var processedAudioDuration: TimeInterval = 0

            try await AudioConverter.shared.convertToWhisperChunks(
                inputURL: url,
                chunkDuration: transcriptionChunkDuration
            ) { [weak self] chunk in
                guard let self else { throw TranscriptionPipelineError.transcriptionFailed }
                let chunkPrompt = self.makeChunkPrompt(basePrompt: prompt, previousText: textParts.joined(separator: "\n"))
                let totalDuration = chunk.totalDuration > 0 ? chunk.totalDuration : max(duration, chunk.startTime + chunk.duration)
                let progressStart = totalDuration > 0 ? min(chunk.startTime / totalDuration, 0.99) : 0
                let progressSpan = totalDuration > 0 ? max(chunk.duration / totalDuration, 0.01) : 0.01

                self.processingStatusText = String(localized: "Transcribing...")
                let result = await self.whisperContext.transcribeChunk(
                    samples: chunk.samples,
                    startOffset: chunk.startTime,
                    segmentIDOffset: combinedSegments.count,
                    language: language,
                    translate: self.settings.translateToEnglish,
                    prompt: chunkPrompt,
                    useVAD: useVAD,
                    vadModelPath: useVAD ? self.modelManager.vadModelPath : nil,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            self?.transcriptionProgress = min(progressStart + progress * progressSpan, 0.99)
                        }
                    }
                )

                guard let result else {
                    AppLogger.error(
                        "Whisper transcription chunk failed: file=\(url.lastPathComponent), chunk=\(chunk.index), start=\(chunk.startTime), whisperError=\(self.whisperContext.errorMessage ?? "none")",
                        context: "TranscribeViewModel"
                    )
                    throw TranscriptionPipelineError.whisperFailed(self.whisperContext.errorMessage)
                }

                if !result.text.isEmpty {
                    textParts.append(result.text)
                }
                combinedSegments.append(contentsOf: result.segments)
                detectedLanguage = detectedLanguage ?? result.language
                processedAudioDuration = chunk.startTime + chunk.duration
                if totalDuration > 0 {
                    self.transcriptionProgress = min(processedAudioDuration / totalDuration, 0.99)
                }
                self.processingStatusText = String(localized: "Converting...")
            }

            let finalText = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else {
                throw TranscriptionPipelineError.emptyTranscription
            }

            AppLogger.info(
                "文字起こしが完了しました: file=\(url.lastPathComponent), textLength=\(finalText.count), segments=\(combinedSegments.count), language=\(detectedLanguage ?? "unknown")",
                context: "TranscribeViewModel"
            )
            transcriptionProgress = 1
            transcriptionResult = finalText
            transcriptionSegments = combinedSegments
            transcriptionLanguage = detectedLanguage
            showResult = true

            let title = makeTitle(from: finalText)
            let record = TranscriptionRecord(
                title: title.isEmpty ? String(localized: "Untitled Transcription") : title,
                text: finalText,
                sourceType: sourceType,
                audioFilePath: sourceType == .recording ? url.path : nil,
                duration: max(duration, processedAudioDuration),
                segments: combinedSegments,
                language: detectedLanguage
            )
            modelContext.insert(record)
            do {
                try modelContext.save()
            } catch {
                modelContext.delete(record)
                setError(String(localized: "Failed to save history") + ": \(error.localizedDescription)")
            }

            if settings.autoDeleteRecordings && sourceType == .recording {
                scheduleRecordingDeletion(url: url)
            }
        } catch {
            AppLogger.error(
                "Exception during transcription pipeline: file=\(url.lastPathComponent), source=\(sourceType)",
                context: "TranscribeViewModel",
                error: error
            )
            setError(error.localizedDescription)
        }
    }
    
    private func loadModelAsync() async -> Bool {
        whisperContext.loadModel(
            path: modelManager.modelPath,
            useFlashAttention: settings.useFlashAttention
        )

        while true {
            if whisperContext.isModelLoaded || whisperContext.errorMessage != nil {
                return whisperContext.isModelLoaded
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
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

    private func makeTitle(from text: String) -> String {
        let prefix = text.prefix(20)
        return String(prefix) + (prefix.endIndex == text.endIndex ? "" : "...")
    }

    private func makeChunkPrompt(basePrompt: String, previousText: String) -> String {
        let trimmedBasePrompt = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPreviousText = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPreviousText.isEmpty else {
            return trimmedBasePrompt
        }

        let contextTail = String(trimmedPreviousText.suffix(800))
        guard !trimmedBasePrompt.isEmpty else {
            return contextTail
        }
        return "\(trimmedBasePrompt)\n\(contextTail)"
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
}

private enum TranscriptionPipelineError: LocalizedError {
    case transcriptionFailed
    case whisperFailed(String?)
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .transcriptionFailed:
            return String(localized: "Transcription failed")
        case .whisperFailed(let message):
            return message ?? String(localized: "Transcription failed")
        case .emptyTranscription:
            return String(localized: "Transcription finished, but no text was produced.")
        }
    }
}
