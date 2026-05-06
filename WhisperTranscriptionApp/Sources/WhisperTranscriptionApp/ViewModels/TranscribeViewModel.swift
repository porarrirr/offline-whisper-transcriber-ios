import Foundation
import SwiftData
import Combine

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
    
    private let audioRecorder = AudioRecorder()
    private let whisperContext = WhisperContext()
    private let modelManager = ModelManager.shared
    private let settings = AppSettings.shared
    
    var audioLevel: Float {
        audioRecorder.audioLevel
    }
    
    init() {
        audioRecorder.$currentTime
            .receive(on: DispatchQueue.main)
            .assign(to: &$recordingDuration)
    }
    
    func startRecording() {
        audioRecorder.requestPermission { [weak self] granted in
            guard let self = self else { return }
            if granted {
                DispatchQueue.main.async {
                    do {
                        try self.audioRecorder.startRecording()
                        self.isRecording = true
                        self.transcriptionResult = ""
                        self.transcriptionSegments = []
                        self.errorMessage = nil
                        self.transcriptionProgress = 0
                        
                        if self.settings.keepScreenOn {
                            UIApplication.shared.isIdleTimerDisabled = true
                        }
                    } catch {
                        self.errorMessage = error.localizedDescription
                    }
                }
            } else {
                self.errorMessage = "マイクの使用許可が必要です"
            }
        }
    }
    
    func stopRecordingAndTranscribe(modelContext: ModelContext) {
        guard let recordingURL = audioRecorder.stopRecording() else {
            errorMessage = "録音の保存に失敗しました"
            isRecording = false
            return
        }
        
        isRecording = false
        recordingDuration = audioRecorder.currentTime
        
        Task {
            await transcribeAudio(url: recordingURL, sourceType: .recording, modelContext: modelContext)
        }
    }
    
    func transcribeFile(url: URL, modelContext: ModelContext) {
        Task {
            await transcribeAudio(url: url, sourceType: .file, modelContext: modelContext)
        }
    }
    
    private func transcribeAudio(url: URL, sourceType: TranscriptionRecord.SourceType, modelContext: ModelContext) async {
        guard modelManager.isModelReady else {
            errorMessage = "モデルが準備できていません"
            return
        }
        
        isProcessing = true
        showResult = false
        transcriptionProgress = 0
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        defer {
            isProcessing = false
            transcriptionProgress = 0
            UIApplication.shared.isIdleTimerDisabled = false
        }
        
        do {
            guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                errorMessage = "音声変換用の保存先を取得できませんでした"
                return
            }
            let wavURL = documentsPath.appendingPathComponent("temp_\(UUID().uuidString).wav")
            defer {
                if FileManager.default.fileExists(atPath: wavURL.path) {
                    try? FileManager.default.removeItem(at: wavURL)
                }
            }
            
            try await AudioConverter.shared.convertToWav(inputURL: url, outputURL: wavURL)
            
            if whisperContext.isModelLoaded == false {
                let loaded = await loadModelAsync()
                guard loaded else {
                    errorMessage = whisperContext.errorMessage ?? "モデルの読み込みに失敗しました"
                    return
                }
            }
            
            let language = settings.selectedLanguage == "auto" ? "" : settings.selectedLanguage
            let prompt = settings.promptText
            let useVAD = settings.useVAD
            
            if let result = await whisperContext.transcribe(
                audioPath: wavURL.path,
                language: language,
                translate: settings.translateToEnglish,
                prompt: prompt,
                useVAD: useVAD,
                onProgress: { [weak self] progress in
                    self?.transcriptionProgress = progress
                }
            ) {
                transcriptionResult = result.text
                transcriptionSegments = result.segments
                transcriptionLanguage = result.language
                showResult = true
                
                let duration = AudioConverter.shared.getAudioDuration(url: url)
                let title = String(result.text.prefix(20)) + (result.text.count > 20 ? "..." : "")
                let record = TranscriptionRecord(
                    title: title.isEmpty ? "無題の文字起こし" : title,
                    text: result.text,
                    sourceType: sourceType,
                    audioFilePath: sourceType == .recording ? url.path : nil,
                    duration: duration,
                    segments: result.segments,
                    language: result.language
                )
                modelContext.insert(record)
                do {
                    try modelContext.save()
                } catch {
                    modelContext.delete(record)
                    errorMessage = "履歴の保存に失敗しました: \(error.localizedDescription)"
                }
                
                if settings.autoDeleteRecordings && sourceType == .recording {
                    scheduleRecordingDeletion(url: url)
                }
            } else {
                errorMessage = whisperContext.errorMessage ?? "文字起こしに失敗しました"
            }
        } catch {
            errorMessage = "音声変換エラー: \(error.localizedDescription)"
        }
    }
    
    private func loadModelAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            whisperContext.loadModel(
                path: modelManager.modelPath,
                useFlashAttention: settings.useFlashAttention
            )
            
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
                if self?.whisperContext.isModelLoaded == true || self?.whisperContext.errorMessage != nil {
                    timer.invalidate()
                    continuation.resume(returning: self?.whisperContext.isModelLoaded == true)
                }
            }
        }
    }
    
    private func scheduleRecordingDeletion(url: URL) {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 7 * 24 * 60 * 60) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    func reset() {
        transcriptionResult = ""
        transcriptionSegments = []
        transcriptionLanguage = nil
        showResult = false
        errorMessage = nil
        transcriptionProgress = 0
    }
}
