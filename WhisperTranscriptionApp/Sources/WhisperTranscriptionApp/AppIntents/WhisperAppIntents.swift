import Foundation
import AppIntents
import SwiftData
import UniformTypeIdentifiers

@available(iOS 18.0, *)
struct TranscribeAudioIntent: AppIntent {
    static var title: LocalizedStringResource = "文字起こしを開始"
    static var description = IntentDescription("音声ファイルを文字起こしします")
    
    @Parameter(title: "音声ファイル", description: "文字起こしする音声ファイル")
    var audioFile: IntentFile?
    
    @Parameter(title: "言語", description: "文字起こしの言語")
    var language: String?
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let modelManager = ModelManager.shared
        let settings = AppSettings.shared
        
        guard modelManager.isModelReady else {
            throw IntentError.modelNotReady
        }
        
        let whisperContext = WhisperContext()
        let modelPath = modelManager.modelPath
        
        await withCheckedContinuation { continuation in
            whisperContext.loadModel(path: modelPath, useFlashAttention: settings.useFlashAttention)
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                if whisperContext.isModelLoaded || whisperContext.errorMessage != nil {
                    timer.invalidate()
                    continuation.resume()
                }
            }
        }
        
        guard whisperContext.isModelLoaded else {
            throw IntentError.modelLoadFailed
        }
        
        guard let audioFile else {
            throw IntentError.noAudioFile
        }

        let transcriptionText = try await audioFile.withFile(contentType: .audio, allowOpenInPlace: true) { audioURL, _ in
            guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw IntentError.documentsDirectoryUnavailable
            }
            let wavURL = documentsPath.appendingPathComponent("shortcut_\(UUID().uuidString).wav")
            defer {
                if FileManager.default.fileExists(atPath: wavURL.path) {
                    try? FileManager.default.removeItem(at: wavURL)
                }
            }
            
            do {
                try await AudioConverter.shared.convertToWav(inputURL: audioURL, outputURL: wavURL)
            } catch {
                throw IntentError.conversionFailed
            }
            
            let selectedLanguage = language ?? settings.selectedLanguage
            if settings.useVAD && !modelManager.isVADModelReady {
                throw IntentError.vadModelNotReady
            }
            let result = await whisperContext.transcribe(
                audioPath: wavURL.path,
                language: selectedLanguage,
                translate: settings.translateToEnglish,
                prompt: settings.promptText,
                useVAD: settings.useVAD,
                vadModelPath: settings.useVAD ? modelManager.vadModelPath : nil
            )

            guard let transcriptionResult = result else {
                throw IntentError.transcriptionFailed
            }
            
            return transcriptionResult.text
        }
        
        return .result(value: transcriptionText)
    }
}

@available(iOS 16.0, *)
struct GetTranscriptionHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "文字起こし履歴を取得"
    static var description = IntentDescription("最近の文字起こし履歴を取得します")
    
    @Parameter(title: "件数", description: "取得する履歴の件数", default: 5)
    var limit: Int
    
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let modelContainer = try ModelContainer(for: TranscriptionRecord.self)
        let modelContext = ModelContext(modelContainer)
        
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        
        let records = try modelContext.fetch(descriptor)
        let limitedRecords = Array(records.prefix(limit))
        
        let result = limitedRecords.map { record in
            "[\(record.formattedDate)] \(record.text.prefix(100))\(record.text.count > 100 ? "..." : "")"
        }.joined(separator: "\n\n")
        
        return .result(value: result)
    }
}

@available(iOS 18.0, *)
struct WhisperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TranscribeAudioIntent(),
            phrases: [
                "\(.applicationName)で文字起こし",
                "\(.applicationName)で音声を文字起こし",
                "\(.applicationName)でファイルを文字起こし"
            ],
            shortTitle: "文字起こし",
            systemImageName: "waveform"
        )
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case modelNotReady
    case modelLoadFailed
    case noAudioFile
    case documentsDirectoryUnavailable
    case conversionFailed
    case transcriptionFailed
    case vadModelNotReady
    
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .modelNotReady:
            return "モデルが準備できていません。アプリを開いてモデルをダウンロードしてください。"
        case .modelLoadFailed:
            return "モデルの読み込みに失敗しました。"
        case .noAudioFile:
            return "音声ファイルが指定されていません。"
        case .documentsDirectoryUnavailable:
            return "一時ファイルの保存先を取得できませんでした。"
        case .conversionFailed:
            return "音声ファイルの変換に失敗しました。"
        case .transcriptionFailed:
            return "文字起こしに失敗しました。"
        case .vadModelNotReady:
            return "VADモデルが準備できていません。アプリを開いて設定からVADモデルをダウンロードしてください。"
        }
    }
}
