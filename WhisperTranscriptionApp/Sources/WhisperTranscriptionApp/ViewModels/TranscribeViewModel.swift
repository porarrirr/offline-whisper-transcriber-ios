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
                        self.setError(error.localizedDescription)
                    }
                }
            } else {
                self.setError("マイクの使用許可が必要です")
            }
        }
    }
    
    func stopRecordingAndTranscribe(modelContext: ModelContext) {
        guard let recordingURL = audioRecorder.stopRecording() else {
            setError("録音の保存に失敗しました")
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
            setError("モデルが準備できていません")
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
            AppLogger.info(
                "文字起こしを開始しました: source=\(sourceType), file=\(url.lastPathComponent), language=\(settings.selectedLanguage), translate=\(settings.translateToEnglish), useVAD=\(settings.useVAD)",
                context: "TranscribeViewModel"
            )
            let samples = try await AudioConverter.shared.convertToWhisperSamples(inputURL: url)
            AppLogger.info(
                "音声変換が完了しました: file=\(url.lastPathComponent), samples=\(samples.count)",
                context: "TranscribeViewModel"
            )
            
            if whisperContext.isModelLoaded == false {
                AppLogger.info("Whisperモデルを読み込みます", context: "TranscribeViewModel")
                let loaded = await loadModelAsync()
                guard loaded else {
                    setError(whisperContext.errorMessage ?? "モデルの読み込みに失敗しました")
                    return
                }
                AppLogger.info("Whisperモデルの読み込みが完了しました", context: "TranscribeViewModel")
            }
            
            let language = settings.selectedLanguage == "auto" ? "" : settings.selectedLanguage
            let prompt = settings.promptText
            let useVAD = settings.useVAD
            if useVAD && !modelManager.isVADModelReady {
                setError("VADモデルが準備できていません。設定からVADモデルをダウンロードしてください。")
                return
            }
            
            if let result = await whisperContext.transcribe(
                samples: samples,
                language: language,
                translate: settings.translateToEnglish,
                prompt: prompt,
                useVAD: useVAD,
                vadModelPath: useVAD ? modelManager.vadModelPath : nil,
                onProgress: { [weak self] progress in
                    self?.transcriptionProgress = progress
                }
            ) {
                AppLogger.info(
                    "文字起こしが完了しました: file=\(url.lastPathComponent), textLength=\(result.text.count), segments=\(result.segments.count), language=\(result.language ?? "unknown")",
                    context: "TranscribeViewModel"
                )
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
                    setError("履歴の保存に失敗しました: \(error.localizedDescription)")
                }
                
                if settings.autoDeleteRecordings && sourceType == .recording {
                    scheduleRecordingDeletion(url: url)
                }
            } else {
                AppLogger.error(
                    "Whisperの文字起こし結果がnilでした: file=\(url.lastPathComponent), samples=\(samples.count), whisperError=\(whisperContext.errorMessage ?? "none")",
                    context: "TranscribeViewModel"
                )
                setError(whisperContext.errorMessage ?? "文字起こしに失敗しました")
            }
        } catch {
            AppLogger.error(
                "音声変換で例外が発生しました: file=\(url.lastPathComponent), source=\(sourceType)",
                context: "TranscribeViewModel",
                error: error
            )
            setError("音声変換エラー: \(error.localizedDescription)")
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
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                AppLogger.error("録音ファイルの自動削除に失敗しました", context: "TranscribeViewModel", error: error)
            }
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
        showResult = false
        errorMessage = nil
        transcriptionProgress = 0
    }
}
