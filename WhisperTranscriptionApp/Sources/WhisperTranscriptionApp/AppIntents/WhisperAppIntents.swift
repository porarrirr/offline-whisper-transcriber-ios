import Foundation
import AppIntents
import SwiftData
import UniformTypeIdentifiers

@available(iOS 18.0, *)
struct TranscribeAudioIntent: AppIntent {
    static var title: LocalizedStringResource = "Transcribe Media"
    static var description = IntentDescription("Transcribes an audio or video file")
    
    @Parameter(title: "Audio or Video File", description: "Audio or video file to transcribe")
    var audioFile: IntentFile?
    
    @Parameter(title: "Language", description: "Language for transcription")
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

        let transcriptionText = try await audioFile.withFile(contentType: .audiovisualContent, allowOpenInPlace: true) { audioURL, _ in
            let samples: [Float]
            do {
                samples = try await AudioConverter.shared.convertToWhisperSamples(inputURL: audioURL)
            } catch {
                throw IntentError.conversionFailed
            }

            let selectedLanguage = language ?? settings.selectedLanguage
            if settings.useVAD && !modelManager.isVADModelReady {
                throw IntentError.vadModelNotReady
            }
            let result = await whisperContext.transcribe(
                samples: samples,
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
    static var title: LocalizedStringResource = "Get Transcription History"
    static var description = IntentDescription("Retrieves recent transcription history")
    
    @Parameter(title: "Count", description: "Number of history records to retrieve", default: 5)
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
                "Transcribe with \(.applicationName)",
                "Transcribe media with \(.applicationName)",
                "Transcribe file with \(.applicationName)"
            ],
            shortTitle: "Transcribe",
            systemImageName: "waveform"
        )
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case modelNotReady
    case modelLoadFailed
    case noAudioFile
    case conversionFailed
    case transcriptionFailed
    case vadModelNotReady
    
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .modelNotReady:
            return "Model is not ready. Please open the app and download the model."
        case .modelLoadFailed:
            return "Failed to load model."
        case .noAudioFile:
            return "No audio or video file specified."
        case .conversionFailed:
            return "Failed to convert audio or video file."
        case .transcriptionFailed:
            return "Transcription failed."
        case .vadModelNotReady:
            return "VAD model is not ready. Please open the app and download the VAD model from settings."
        }
    }
}
