import Foundation
import AppIntents
import Speech
import SwiftData
import UniformTypeIdentifiers

enum WhisperAppDestination: String {
    case transcribe
    case history

    static let pendingDestinationKey = "WhisperAppIntentPendingDestination"
    static let pendingLiveRecordingKey = "WhisperAppIntentPendingLiveRecording"

    var tabIndex: Int {
        switch self {
        case .transcribe:
            return 0
        case .history:
            return 1
        }
    }

    @MainActor
    func requestOpen(liveTranscriptionRequested: Bool = false) {
        UserDefaults.standard.set(rawValue, forKey: Self.pendingDestinationKey)
        if liveTranscriptionRequested {
            UserDefaults.standard.set(true, forKey: Self.pendingLiveRecordingKey)
        }
    }
}

@available(iOS 18.0, *)
struct OpenTranscriptionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Whisper Transcriber"
    static var description = IntentDescription("Opens the app for recording or file transcription")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WhisperAppDestination.transcribe.requestOpen()
        return .result()
    }
}

@available(iOS 18.0, *)
struct OpenTranscriptionHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Transcription History"
    static var description = IntentDescription("Opens saved transcription history")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WhisperAppDestination.history.requestOpen()
        return .result()
    }
}

@available(iOS 18.0, *)
struct StartBackgroundRecordingIntent: AppIntent, AudioRecordingIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description = IntentDescription("Starts an audio recording in the background")
    static var openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        do {
            switch try await RecordingService.shared.startRecordingFromIntent() {
            case .started:
                return .result(value: String(localized: "Recording started."))
            case .alreadyRecording:
                return .result(value: String(localized: "Recording is already in progress."))
            }
        } catch AudioRecorderError.microphonePermissionRequired {
            throw IntentError.microphonePermissionRequired
        } catch AudioRecorderError.stopInProgress {
            throw IntentError.recordingBusy
        } catch is RecordingLiveActivityError {
            throw IntentError.liveActivityRequired
        } catch {
            throw IntentError.recordingStartFailed
        }
    }
}

@available(iOS 18.0, *)
struct OpenLiveRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Live Recorder"
    static var description = IntentDescription("Opens the recorder with live transcription selected")
    static var openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @MainActor
    func perform() async throws -> some IntentResult {
        WhisperAppDestination.transcribe.requestOpen(liveTranscriptionRequested: true)
        return .result()
    }
}

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

        guard let audioFile else {
            throw IntentError.noAudioFile
        }

        let transcriptionText = try await audioFile.withFile(contentType: .audiovisualContent, allowOpenInPlace: true) { audioURL, _ in
            switch settings.selectedTranscriptionModel.backend {
            case .whisper:
                return try await transcribeWithWhisperIntent(
                    audioURL: audioURL,
                    modelManager: modelManager,
                    settings: settings,
                    languageOverride: language
                )
            case .appleSpeech(let locale):
                return try await transcribeWithAppleSpeechIntent(
                    inputURL: audioURL,
                    locale: locale
                )
            }
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
            intent: StartBackgroundRecordingIntent(),
            phrases: [
                "Start recording with \(.applicationName)",
                "Record audio with \(.applicationName)",
                "Begin recording with \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: OpenLiveRecordingIntent(),
            phrases: [
                "Open live recorder with \(.applicationName)",
                "Start live recording with \(.applicationName)",
                "Open live transcription with \(.applicationName)"
            ],
            shortTitle: "Live Recorder",
            systemImageName: "quote.bubble"
        )
        AppShortcut(
            intent: OpenTranscriptionIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Start transcription with \(.applicationName)",
                "Open recorder with \(.applicationName)",
                "Open audio transcription with \(.applicationName)"
            ],
            shortTitle: "Open Transcriber",
            systemImageName: "mic.circle"
        )
        AppShortcut(
            intent: TranscribeAudioIntent(),
            phrases: [
                "Transcribe with \(.applicationName)",
                "Transcribe audio with \(.applicationName)",
                "Transcribe media with \(.applicationName)",
                "Transcribe file with \(.applicationName)"
            ],
            shortTitle: "Transcribe File",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: OpenTranscriptionHistoryIntent(),
            phrases: [
                "Open history in \(.applicationName)",
                "Show transcription history in \(.applicationName)",
                "Find transcripts in \(.applicationName)"
            ],
            shortTitle: "History",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}

@MainActor
private func transcribeWithWhisperIntent(
    audioURL: URL,
    modelManager: ModelManager,
    settings: AppSettings,
    languageOverride: String?
) async throws -> String {
    guard modelManager.currentWhisperModelIsReady() else {
        throw IntentError.modelNotReady
    }

    do {
        try await WhisperModelService.shared.ensureModelLoaded(
            path: modelManager.modelPath,
            useFlashAttention: settings.useFlashAttention
        )
    } catch {
        throw IntentError.modelLoadFailed
    }

    let selectedLanguage = languageOverride ?? settings.selectedLanguage
    if settings.useVAD && !modelManager.isVADModelReady {
        throw IntentError.vadModelNotReady
    }

    do {
        let result = try await WhisperModelService.shared.transcribe(
            inputURL: audioURL,
            language: selectedLanguage == "auto" ? "" : selectedLanguage,
            translate: settings.translateToEnglish,
            prompt: settings.promptText,
            useVAD: settings.useVAD,
            vadModelPath: settings.useVAD ? modelManager.vadModelPath : nil,
            onChunkProgress: { _, _ in }
        )
        return result.text
    } catch is AudioConverter.AudioConverterError {
        throw IntentError.conversionFailed
    } catch is CancellationError {
        throw IntentError.transcriptionFailed
    } catch {
        throw IntentError.transcriptionFailed
    }
}

@MainActor
@available(iOS 18.0, *)
private func transcribeWithAppleSpeechIntent(inputURL: URL, locale: AppleSpeechLocale) async throws -> String {
    guard #available(iOS 26.0, *) else {
        throw IntentError.speechUnavailable
    }
    guard SpeechTranscriber.isAvailable else {
        throw IntentError.speechUnavailable
    }

    do {
        let result = try await AppleSpeechTranscriptionService().transcribe(
            inputURL: inputURL,
            locale: locale,
            includeTimestamps: false
        ) { _ in }
        return result.text
    } catch AppleSpeechTranscriptionError.localeNotSupported {
        throw IntentError.speechLocaleNotSupported
    } catch AppleSpeechTranscriptionError.transcriptionUnavailable {
        throw IntentError.speechUnavailable
    } catch AppleSpeechTranscriptionError.assetsNotReady {
        throw IntentError.modelNotReady
    } catch is AudioConverter.AudioConverterError {
        throw IntentError.conversionFailed
    } catch {
        throw IntentError.transcriptionFailed
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case modelNotReady
    case modelLoadFailed
    case noAudioFile
    case conversionFailed
    case transcriptionFailed
    case coreMLEncoderNotReady
    case vadModelNotReady
    case speechUnavailable
    case speechLocaleNotSupported
    case microphonePermissionRequired
    case recordingBusy
    case recordingStartFailed
    case liveActivityRequired
    
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
        case .coreMLEncoderNotReady:
            return "Core ML encoder is required. Please open the app and download the additional encoder model."
        case .vadModelNotReady:
            return "VAD model is not ready. Please open the app and download the VAD model from settings."
        case .speechUnavailable:
            return "Speech transcription is not available on this device."
        case .speechLocaleNotSupported:
            return "This language is not supported by on-device speech recognition."
        case .microphonePermissionRequired:
            return "Microphone permission is required. Please allow microphone access in Settings."
        case .recordingBusy:
            return "Recording is already starting or stopping."
        case .recordingStartFailed:
            return "Failed to start recording."
        case .liveActivityRequired:
            return "Live Activities must be enabled to start recording from a shortcut."
        }
    }
}
